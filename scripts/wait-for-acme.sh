#!/usr/bin/env bash
# Wait until the Teleport proxy serves a working certificate for
# https://$TELEPORT_CLUSTER_NAME and answers /webapi/ping.
#
# Usage: scripts/wait-for-acme.sh
#
# Env: TELEPORT_CLUSTER_NAME  required
#      K8S_NAMESPACE_CLUSTER  required (for logs / rollout restart)
#      ACME_USE_STAGING       "true" to accept the Let's Encrypt *staging* issuer
#      ACME_TIMEOUT_SECONDS   default 900 (15 min)
#      ACME_INTERVAL_SECONDS  default 15
#      ACME_RESTART_AFTER_SECONDS  default 300; after this long with no valid
#                             certificate, the proxy Deployment is restarted ONCE
#                             to kick Teleport's ACME retry loop. Not done
#                             unconditionally -- see the ordering note in SPEC.md §6.1.
#
# Background: helm install completes before DNS exists, so the proxy first comes
# up with a self-signed certificate. Once Route53 points at the load balancer,
# Teleport's ACME loop can complete the TLS-ALPN-01 challenge on :443. This script
# is the gate between "DNS written" and "the cluster is usable".
#
# Outputs (when $GITHUB_OUTPUT is set): acme_issuer=<observed certificate issuer>
set -euo pipefail

die() {
	echo "::error title=wait-for-acme::$*" >&2
	exit 1
}

[ -n "${TELEPORT_CLUSTER_NAME:-}" ] || die "TELEPORT_CLUSTER_NAME is not set"
[ -n "${K8S_NAMESPACE_CLUSTER:-}" ] || die "K8S_NAMESPACE_CLUSTER is not set"

host="${TELEPORT_CLUSTER_NAME%.}"
ns="$K8S_NAMESPACE_CLUSTER"
timeout="${ACME_TIMEOUT_SECONDS:-900}"
interval="${ACME_INTERVAL_SECONDS:-15}"
restart_after="${ACME_RESTART_AFTER_SECONDS:-300}"
staging="${ACME_USE_STAGING:-false}"

proxy_selector='app.kubernetes.io/name=teleport-cluster,app.kubernetes.io/component=proxy'
auth_selector='app.kubernetes.io/name=teleport-cluster,app.kubernetes.io/component=auth'

curl_opts=(--silent --show-error --location --max-time 15 -o /dev/null -w '%{http_code}')
if [ "$staging" = "true" ]; then
	cat >&2 <<-'EOF'
		::warning title=wait-for-acme::ACME_USE_STAGING=true -- TLS VERIFICATION IS DISABLED
		The Let's Encrypt *staging* CA is not publicly trusted, so this script cannot
		verify the certificate chain and will accept any certificate whose issuer names
		the staging CA. The teleport-kube-agent still verifies the proxy certificate
		against the system trust store, so the kube agent WILL FAIL TO JOIN while
		staging is in use. Use ACME_USE_STAGING=true only to iterate on the workflow
		plumbing, and flip it back to false before expecting a green deploy.
		See SPEC.md §9.3.
	EOF
	curl_opts+=(--insecure)
	expect_issuer='STAGING'
else
	expect_issuer="Let's Encrypt"
fi

observe_issuer() {
	# Observe whatever certificate is on the wire, without verifying it, so the
	# log shows the transition from the Teleport self-signed CA to Let's Encrypt.
	if command -v openssl >/dev/null 2>&1; then
		openssl s_client -connect "${host}:443" -servername "$host" </dev/null 2>/dev/null |
			openssl x509 -noout -issuer 2>/dev/null |
			sed -e 's/^issuer=//' -e 's/[[:space:]]\+/ /g' ||
			true
	fi
}

dump_evidence() {
	echo "----- proxy pods -----"
	kubectl -n "$ns" get pods -l "$proxy_selector" -o wide || true
	echo "----- proxy logs (tail 200) -----"
	kubectl -n "$ns" logs -l "$proxy_selector" -c teleport --tail=200 || true
	echo "----- auth logs (tail 100) -----"
	kubectl -n "$ns" logs -l "$auth_selector" -c teleport --tail=100 || true
	echo "----- what does $host resolve to? -----"
	getent hosts "$host" || echo "(name does not resolve from the runner)"
}

restart_done=false
start=$SECONDS
attempt=0

while :; do
	attempt=$((attempt + 1))
	elapsed=$((SECONDS - start))

	issuer="$(observe_issuer)"
	code="$(curl "${curl_opts[@]}" "https://${host}/webapi/ping" 2>/dev/null || echo "000")"

	printf 'attempt %d (%ds elapsed): HTTP %s, issuer: %s\n' \
		"$attempt" "$elapsed" "$code" "${issuer:-<no TLS handshake>}"

	if [ "$code" = "200" ]; then
		case "$issuer" in
		*"$expect_issuer"*)
			echo "proxy is serving a certificate from '$issuer' and /webapi/ping returns 200"
			if [ -n "${GITHUB_OUTPUT:-}" ]; then
				echo "acme_issuer=$issuer" >>"$GITHUB_OUTPUT"
			fi
			exit 0
			;;
		*)
			# In production mode a 200 with strict verification already proves the
			# chain is publicly trusted, so this is only a sanity note.
			echo "::warning title=wait-for-acme::/webapi/ping returned 200 but the issuer '$issuer' does not mention '$expect_issuer'"
			if [ "$staging" != "true" ]; then
				echo "certificate verified against the system trust store; accepting."
				if [ -n "${GITHUB_OUTPUT:-}" ]; then
					echo "acme_issuer=$issuer" >>"$GITHUB_OUTPUT"
				fi
				exit 0
			fi
			;;
		esac
	fi

	if [ "$restart_done" = false ] && [ "$elapsed" -ge "$restart_after" ]; then
		restart_done=true
		echo "::warning title=wait-for-acme::no valid certificate after ${elapsed}s; restarting the proxy Deployment once to re-trigger the ACME loop"
		kubectl -n "$ns" rollout restart deploy -l "$proxy_selector" || true
		kubectl -n "$ns" rollout status deploy -l "$proxy_selector" --timeout=5m || true
	fi

	if [ "$elapsed" -ge "$timeout" ]; then
		echo "::error title=wait-for-acme::timed out after ${elapsed}s waiting for a valid certificate on https://${host}" >&2
		cat >&2 <<-EOF

			The most common causes, in order:
			  1. The Service LoadBalancer terminates TLS (an L7 / HTTP load balancer).
			     Teleport's ACME uses the TLS-ALPN-01 challenge on port 443 and needs an
			     L4 / TCP passthrough load balancer. See docs/runbook.md.
			  2. DNS for ${host} does not resolve to the load balancer yet, or the NS
			     delegation for the parent zone is not actually live.
			  3. Let's Encrypt rate limiting (5 duplicate certificates per registered
			     domain per 168h). Set ACME_USE_STAGING=true while iterating.
			  4. The load balancer's security group / firewall blocks inbound :443 from
			     the internet, so Let's Encrypt cannot reach it.
		EOF
		dump_evidence >&2
		exit 1
	fi

	sleep "$interval"
done
