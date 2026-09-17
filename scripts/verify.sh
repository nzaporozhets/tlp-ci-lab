#!/usr/bin/env bash
# Assert that the Teleport cluster and both agents are healthy.
#
# Usage: scripts/verify.sh
#
# Every cluster-side assertion goes through scripts/tctl.sh (kubectl exec into the
# auth pod), so verification needs no Teleport user and no `tsh login`.
#
# Env: TELEPORT_CLUSTER_NAME   required
#      TELEPORT_VERSION        required (asserted against the running version)
#      K8S_NAMESPACE_CLUSTER   required
#      KUBE_CLUSTER_NAME       required when CHECK_KUBE_AGENT=true
#      EC2_INSTANCE_ID         required when CHECK_EC2_AGENT=true
#      CHECK_KUBE_AGENT        default true
#      CHECK_EC2_AGENT         default true
#      ACME_USE_STAGING        default false; when true the public-trust check is
#                              reported as skipped instead of failing
#      VERIFY_TIMEOUT_SECONDS  default 300 (agents take tens of seconds to appear)
set -euo pipefail

: "${TELEPORT_CLUSTER_NAME:?TELEPORT_CLUSTER_NAME is not set}"
: "${TELEPORT_VERSION:?TELEPORT_VERSION is not set}"
: "${K8S_NAMESPACE_CLUSTER:?K8S_NAMESPACE_CLUSTER is not set}"

host="${TELEPORT_CLUSTER_NAME%.}"
check_kube="${CHECK_KUBE_AGENT:-true}"
check_ec2="${CHECK_EC2_AGENT:-true}"
staging="${ACME_USE_STAGING:-false}"
deadline_secs="${VERIFY_TIMEOUT_SECONDS:-300}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tctl="$here/tctl.sh"

failures=0
declare -a summary_rows=()

pass() {
	echo "PASS  $1"
	summary_rows+=("| ✅ | $1 | ${2:-} |")
}

fail() {
	echo "::error title=verify::FAIL  $1" >&2
	failures=$((failures + 1))
	summary_rows+=("| ❌ | $1 | ${2:-} |")
}

skip() {
	echo "SKIP  $1"
	summary_rows+=("| ⏭️ | $1 | ${2:-skipped} |")
}

# Poll `cmd` (a shell function name) with exponential-ish backoff until it
# succeeds or the deadline passes.
retry() {
	local label="$1"
	shift
	local start=$SECONDS delay=5
	while :; do
		if "$@"; then
			return 0
		fi
		if [ $((SECONDS - start)) -ge "$deadline_secs" ]; then
			echo "  ${label}: still failing after ${deadline_secs}s" >&2
			return 1
		fi
		echo "  ${label}: not ready yet, retrying in ${delay}s"
		sleep "$delay"
		[ "$delay" -lt 30 ] && delay=$((delay * 2))
	done
}

# ---------------------------------------------------------------------------
# 1. tctl status reports the expected cluster name and version.
# ---------------------------------------------------------------------------
echo "== 1. tctl status =="
status_out=""
if status_out="$("$tctl" status 2>&1)"; then
	echo "$status_out"
	if grep -qiF "$host" <<<"$status_out"; then
		pass "tctl status reports cluster name $host"
	else
		fail "tctl status does not mention the expected cluster name $host"
	fi
	if grep -qF "$TELEPORT_VERSION" <<<"$status_out"; then
		pass "auth service runs Teleport $TELEPORT_VERSION"
	else
		fail "auth service version does not match TELEPORT_VERSION=$TELEPORT_VERSION" \
			"see the tctl status output in the job log"
	fi
else
	echo "$status_out" >&2
	fail "tctl status failed"
fi

# ---------------------------------------------------------------------------
# 2. The proxy serves a publicly trusted certificate and the advertised version
#    matches TELEPORT_VERSION.
# ---------------------------------------------------------------------------
echo "== 2. public TLS + /webapi/ping =="
ping_json=""
issuer="unknown"
if command -v openssl >/dev/null 2>&1; then
	issuer="$(openssl s_client -connect "${host}:443" -servername "$host" </dev/null 2>/dev/null |
		openssl x509 -noout -issuer 2>/dev/null | sed -e 's/^issuer=//' -e 's/[[:space:]]\+/ /g' || true)"
	issuer="${issuer:-unknown}"
fi
echo "observed certificate issuer: $issuer"

if [ "$staging" = "true" ]; then
	skip "proxy certificate is publicly trusted" "ACME_USE_STAGING=true (staging CA is not publicly trusted)"
	ping_json="$(curl --insecure --silent --show-error --fail --max-time 20 "https://${host}/webapi/ping" || true)"
else
	# Default CA bundle, no --insecure: this is the public-trust assertion.
	if ping_json="$(curl --silent --show-error --fail --max-time 20 "https://${host}/webapi/ping" 2>&1)"; then
		pass "proxy certificate is publicly trusted" "$issuer"
	else
		echo "$ping_json" >&2
		fail "https://${host}/webapi/ping did not return 200 with the default CA bundle" "$issuer"
		ping_json=""
	fi
fi

if [ -n "$ping_json" ]; then
	server_version="$(jq -r '.server_version // empty' <<<"$ping_json" 2>/dev/null || true)"
	if [ "$server_version" = "$TELEPORT_VERSION" ]; then
		pass "proxy advertises server_version $server_version"
	else
		fail "proxy advertises server_version '${server_version:-<absent>}', expected $TELEPORT_VERSION"
	fi
fi

# ---------------------------------------------------------------------------
# 3. The Kubernetes agent has registered KUBE_CLUSTER_NAME.
# ---------------------------------------------------------------------------
echo "== 3. kube agent =="
kube_servers_json=""
check_kube_server() {
	kube_servers_json="$("$tctl" get kube_servers --format=json 2>/dev/null || echo '[]')"
	jq -e --arg n "$KUBE_CLUSTER_NAME" \
		'[.[] | select(any(..|strings; . == $n))] | length > 0' <<<"$kube_servers_json" >/dev/null
}

if [ "$check_kube" = "true" ]; then
	: "${KUBE_CLUSTER_NAME:?KUBE_CLUSTER_NAME is not set but CHECK_KUBE_AGENT=true}"
	if retry "kube_servers" check_kube_server; then
		pass "kube_servers contains $KUBE_CLUSTER_NAME"
	else
		echo "tctl get kube_servers --format=json:" >&2
		printf '%s\n' "$kube_servers_json" | jq . >&2 || printf '%s\n' "$kube_servers_json" >&2
		fail "no kube_server registered for $KUBE_CLUSTER_NAME"
	fi
else
	skip "kube_servers contains the enrolled cluster" "kube agent not deployed in this run"
fi

# ---------------------------------------------------------------------------
# 4. The EC2 agent has registered, with the managed-by label.
# ---------------------------------------------------------------------------
echo "== 4. EC2 SSH agent =="
nodes_json=""
get_nodes() {
	# `tctl get nodes` is the resource API and is stable across versions;
	# `tctl nodes ls` is the friendlier command. Try both.
	"$tctl" get nodes --format=json 2>/dev/null ||
		"$tctl" nodes ls --format=json 2>/dev/null ||
		echo '[]'
}
check_node() {
	nodes_json="$(get_nodes)"
	jq -e --arg iid "$EC2_INSTANCE_ID" \
		'[.[]
		  | select(any(..|strings; . == $iid))
		  | select(((.metadata.labels // .labels // {})["managed-by"]) == "github-actions")
		 ] | length > 0' <<<"$nodes_json" >/dev/null
}

if [ "$check_ec2" = "true" ]; then
	: "${EC2_INSTANCE_ID:?EC2_INSTANCE_ID is not set but CHECK_EC2_AGENT=true}"
	if retry "nodes" check_node; then
		pass "node $EC2_INSTANCE_ID registered with label managed-by=github-actions"
	else
		echo "tctl get nodes --format=json:" >&2
		printf '%s\n' "$nodes_json" | jq . >&2 || printf '%s\n' "$nodes_json" >&2
		fail "no SSH node found for instance $EC2_INSTANCE_ID with label managed-by=github-actions"
	fi
else
	skip "EC2 node registered" "ec2 agent not deployed in this run"
fi

# ---------------------------------------------------------------------------
# 6. Step summary.
# ---------------------------------------------------------------------------
{
	echo "## Teleport CI verification"
	echo
	echo "| | Assertion | Detail |"
	echo "|---|---|---|"
	printf '%s\n' "${summary_rows[@]}"
	echo
	echo "| Property | Value |"
	echo "|---|---|"
	echo "| Cluster URL | https://${host} |"
	echo "| Teleport version | \`${TELEPORT_VERSION}\` |"
	echo "| Kubernetes cluster | \`${KUBE_CLUSTER_NAME:-(not deployed)}\` |"
	echo "| EC2 node | \`${EC2_INSTANCE_ID:-(not deployed)}\` |"
	echo "| Certificate issuer | \`${issuer}\` |"
	echo "| ACME staging | \`${staging}\` |"
} >>"${GITHUB_STEP_SUMMARY:-/dev/stdout}"

if [ "$failures" -gt 0 ]; then
	echo "::error title=verify::${failures} assertion(s) failed" >&2
	exit 1
fi

echo "all assertions passed"
