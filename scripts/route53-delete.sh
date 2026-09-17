#!/usr/bin/env bash
# Delete the $TELEPORT_CLUSTER_NAME record set from $ROUTE53_ZONE_ID.
#
# Usage: scripts/route53-delete.sh
#
# Env: ROUTE53_ZONE_ID        required
#      TELEPORT_CLUSTER_NAME  required
#
# Route53 DELETE requires the change batch to describe the record set *exactly*
# as it currently exists (type, TTL, values / alias target). So this reads the
# current record from Route53 and echoes it back rather than reconstructing it.
#
# Idempotent (SPEC.md §6.2/§9.2): exits 0 when the record is already absent, so a
# partially completed destroy can simply be re-run.
set -euo pipefail

die() {
	echo "::error title=route53-delete::$*" >&2
	exit 1
}

[ -n "${ROUTE53_ZONE_ID:-}" ] || die "ROUTE53_ZONE_ID is not set"
[ -n "${TELEPORT_CLUSTER_NAME:-}" ] || die "TELEPORT_CLUSTER_NAME is not set"

zone_id="${ROUTE53_ZONE_ID#/hostedzone/}"
fqdn="${TELEPORT_CLUSTER_NAME%.}"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

existing="$(
	aws route53 list-resource-record-sets \
		--hosted-zone-id "$zone_id" \
		--start-record-name "${fqdn}." \
		--max-items 20 \
		--output json
)"

# Only ever touch address records for this exact name. Never NS/SOA, never
# anything at a different name that happened to sort next.
targets="$(
	printf '%s' "$existing" | jq -c --arg n "${fqdn}." \
		'[.ResourceRecordSets[] | select(.Name == $n) | select(.Type == "A" or .Type == "AAAA" or .Type == "CNAME")]'
)"

count="$(printf '%s' "$targets" | jq 'length')"
if [ "$count" -eq 0 ]; then
	echo "no A/AAAA/CNAME record for ${fqdn} in zone ${zone_id}; nothing to delete"
	exit 0
fi

echo "deleting ${count} record(s) for ${fqdn}: $(printf '%s' "$targets" | jq -r '[.[].Type] | join(",")')"

printf '%s' "$targets" |
	jq '{Comment: "teleport-ci teardown", Changes: [.[] | {Action: "DELETE", ResourceRecordSet: .}]}' \
		>"$workdir/delete.json"

# Tolerate a concurrent/duplicate destroy: Route53 returns InvalidChangeBatch
# with "not found" if the record vanished between the list and the change.
set +e
change_id="$(
	aws route53 change-resource-record-sets \
		--hosted-zone-id "$zone_id" \
		--change-batch "file://$workdir/delete.json" \
		--output text --query 'ChangeInfo.Id' 2>"$workdir/err"
)"
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
	if grep -qiE 'not found|InvalidChangeBatch' "$workdir/err"; then
		echo "::warning title=route53-delete::record already absent or changed concurrently; treating as success"
		cat "$workdir/err" >&2
		exit 0
	fi
	cat "$workdir/err" >&2
	die "failed to delete the record set for ${fqdn}"
fi

echo "waiting for change $change_id to propagate"
aws route53 wait resource-record-sets-changed --id "$change_id"
echo "Route53 change $change_id is INSYNC"
