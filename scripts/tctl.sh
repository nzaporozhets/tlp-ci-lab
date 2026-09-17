#!/usr/bin/env bash
# Run tctl against the Teleport cluster by exec'ing into the Auth Service pod.
#
# This is how every administrative action in this repo is performed. It means no
# Teleport *user* credentials exist anywhere in CI: `tctl` run inside the auth
# container talks to the local auth server over its admin socket. See SPEC.md §6.1.
#
# Usage:
#   scripts/tctl.sh apply-file <path>   # `tctl create -f` (upsert) from a local file
#   scripts/tctl.sh <args...>           # run `tctl <args...>` in the auth pod
#
# Env: K8S_NAMESPACE_CLUSTER  namespace of the teleport-cluster release. Required.
#      KUBECONFIG             set by scripts/kubeconfig.sh.
#      TCTL_AUTH_WORKLOAD     optional override, e.g. "deploy/teleport-cluster-auth".
#
# The auth workload is resolved by label selector rather than hardcoded, so a
# chart bump that renames the Deployment does not break this.
set -euo pipefail

die() {
	echo "::error title=tctl::$*" >&2
	exit 1
}

[ -n "${K8S_NAMESPACE_CLUSTER:-}" ] || die "K8S_NAMESPACE_CLUSTER is not set"
ns="$K8S_NAMESPACE_CLUSTER"

resolve_workload() {
	if [ -n "${TCTL_AUTH_WORKLOAD:-}" ]; then
		printf '%s' "$TCTL_AUTH_WORKLOAD"
		return 0
	fi

	local selector name
	# Selectors in preference order. The first is what teleport-cluster >= 12
	# renders; the second covers the older `app=` labelling.
	for selector in \
		'app.kubernetes.io/name=teleport-cluster,app.kubernetes.io/component=auth' \
		'app=teleport-cluster,app.kubernetes.io/component=auth' \
		'app.kubernetes.io/component=auth'; do
		name="$(kubectl -n "$ns" get deploy -l "$selector" \
			-o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
		if [ -n "$name" ]; then
			printf 'deploy/%s' "$name"
			return 0
		fi
	done

	return 1
}

if ! workload="$(resolve_workload)"; then
	echo "::error title=tctl::could not find the Teleport Auth Service Deployment in namespace '$ns'." >&2
	echo "Deployments present:" >&2
	kubectl -n "$ns" get deploy --show-labels >&2 || true
	echo "Set TCTL_AUTH_WORKLOAD (e.g. deploy/teleport-cluster-auth) to override." >&2
	exit 1
fi

case "${1:-}" in
"")
	die "usage: $0 apply-file <path> | $0 <tctl args...>"
	;;
apply-file)
	file="${2:-}"
	[ -n "$file" ] || die "usage: $0 apply-file <path>"
	[ -r "$file" ] || die "cannot read '$file'"
	# `tctl create -f` == force/upsert, with the filename as a positional
	# argument. /dev/stdin lets us stream the file in without copying it into
	# the container.
	exec kubectl -n "$ns" exec -i "$workload" -c teleport -- \
		tctl create -f /dev/stdin <"$file"
	;;
*)
	exec kubectl -n "$ns" exec -i "$workload" -c teleport -- tctl "$@"
	;;
esac
