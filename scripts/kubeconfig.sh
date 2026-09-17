#!/usr/bin/env bash
# Materialise the base64-encoded KUBECONFIG secret into a 0600 file under
# $RUNNER_TEMP and export KUBECONFIG for the remaining steps of the job.
#
# Input  (env): KUBECONFIG_B64  base64 of the kubeconfig (the repo secret)
#               RUNNER_TEMP     GitHub Actions runner temp dir
# Output (env): KUBECONFIG      written to $GITHUB_ENV
#
# Secret hygiene (SPEC.md §9.1): the value is never echoed, never passed as a CLI
# argument, and the file is created with a restrictive umask *before* any data is
# written to it. The runner is persistent, so deploy.yml/destroy.yml must remove
# this file in an always() cleanup step -- $RUNNER_TEMP is not auto-wiped.
set -euo pipefail

die() {
	echo "::error title=kubeconfig::$*" >&2
	exit 1
}

[ -n "${RUNNER_TEMP:-}" ] || die "RUNNER_TEMP is not set; this script expects to run on a GitHub Actions runner"
[ -n "${KUBECONFIG_B64:-}" ] || die "the KUBECONFIG secret is empty or not exposed to this job. Check the teleport-ci environment secrets (SPEC.md §5.2)"

dest="$RUNNER_TEMP/kubeconfig"

# Create the file with 0600 before writing, so the contents are never briefly
# world-readable on a shared persistent runner.
umask 077
rm -f "$dest"
: >"$dest"
chmod 600 "$dest"

# `base64 -d` reads from stdin: the secret never appears in the process table.
if ! printf '%s' "$KUBECONFIG_B64" | base64 -d >"$dest" 2>/dev/null; then
	die "the KUBECONFIG secret is not valid base64. Store it as: base64 -w0 < kubeconfig"
fi

[ -s "$dest" ] || die "the decoded KUBECONFIG secret is empty"

# Cheap structural check with no output, so a raw (un-encoded) kubeconfig or a
# truncated secret fails here with a readable message instead of inside Helm.
if ! grep -q '^apiVersion:' "$dest"; then
	die "the decoded KUBECONFIG does not look like a kubeconfig (no apiVersion key). Did you base64-encode the file?"
fi

export KUBECONFIG="$dest"

# Mask the API server URLs: kubectl and Helm print them in error messages, and on
# a private cluster the endpoint is not something we want in public run logs.
while read -r server; do
	[ -n "$server" ] || continue
	echo "::add-mask::$server"
	host="${server#*://}"
	host="${host%%/*}"
	echo "::add-mask::$host"
	echo "::add-mask::${host%%:*}"
done < <(kubectl config view -o 'jsonpath={range .clusters[*]}{.cluster.server}{"\n"}{end}' 2>/dev/null || true)

# Prove the file is usable before anything else runs.
if ! kubectl config current-context >/dev/null 2>&1; then
	die "the KUBECONFIG has no current-context set. Export it with: kubectl config view --minify --flatten"
fi

if [ -n "${GITHUB_ENV:-}" ]; then
	echo "KUBECONFIG=$dest" >>"$GITHUB_ENV"
fi

echo "kubeconfig materialised at \$RUNNER_TEMP/kubeconfig (mode 0600)"
