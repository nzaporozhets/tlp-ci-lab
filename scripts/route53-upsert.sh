#!/usr/bin/env bash
# Point $TELEPORT_CLUSTER_NAME at the teleport-cluster Service's load balancer.
#
# Usage: scripts/route53-upsert.sh <load-balancer-address>
#
#   <load-balancer-address>  either an IPv4 address (Service
#                            .status.loadBalancer.ingress[0].ip) or a DNS name
#                            (.hostname). Both are produced by real clusters.
#
# Env: ROUTE53_ZONE_ID        hosted zone containing the record. Required.
#      TELEPORT_CLUSTER_NAME  fully-qualified record name. Required.
#      ROUTE53_TTL            default 60.
#      ROUTE53_USE_ALIAS      optional, default false. When true and the address
#                             is an ELB in this account, create a Route53 ALIAS
#                             instead of a CNAME. This needs the extra IAM
#                             permission elasticloadbalancing:DescribeLoadBalancers,
#                             which the runner role in SPEC.md §7.2 does NOT
#                             grant by default -- hence opt-in. See docs/runbook.md.
#
# Uses UPSERT, so it is idempotent (SPEC.md §9.2).
set -euo pipefail

die() {
	echo "::error title=route53-upsert::$*" >&2
	exit 1
}

addr="${1:-}"
[ -n "$addr" ] || die "usage: $0 <load-balancer-address>"
[ -n "${ROUTE53_ZONE_ID:-}" ] || die "ROUTE53_ZONE_ID is not set"
[ -n "${TELEPORT_CLUSTER_NAME:-}" ] || die "TELEPORT_CLUSTER_NAME is not set"

ttl="${ROUTE53_TTL:-60}"
zone_id="${ROUTE53_ZONE_ID#/hostedzone/}"
fqdn="${TELEPORT_CLUSTER_NAME%.}"
addr="${addr%.}"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# ---------------------------------------------------------------------------
# Decide the record type.
# ---------------------------------------------------------------------------
alias_dns_name=""
alias_zone_id=""
if [[ "$addr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
	rtype="A"
	echo "load balancer exposes an IP address -> A record"
elif [[ "$addr" == *:* ]] && [[ "$addr" != *.* ]]; then
	rtype="AAAA"
	echo "load balancer exposes an IPv6 address -> AAAA record"
else
	rtype="CNAME"
	echo "load balancer exposes a DNS name -> CNAME record"
	if [ "${ROUTE53_USE_ALIAS:-false}" = "true" ]; then
		echo "ROUTE53_USE_ALIAS=true: looking for a matching ELB in this account"
		# ELBv2 (NLB/ALB) first, then classic ELB.
		read -r alias_dns_name alias_zone_id < <(
			aws elbv2 describe-load-balancers \
				--query "LoadBalancers[?DNSName=='${addr}'].[DNSName,CanonicalHostedZoneId]" \
				--output text 2>/dev/null | head -n1
		) || true
		if [ -z "${alias_dns_name:-}" ]; then
			read -r alias_dns_name alias_zone_id < <(
				aws elb describe-load-balancers \
					--query "LoadBalancerDescriptions[?DNSName=='${addr}'].[DNSName,CanonicalHostedZoneNameID]" \
					--output text 2>/dev/null | head -n1
			) || true
		fi
		if [ -n "${alias_dns_name:-}" ] && [ -n "${alias_zone_id:-}" ]; then
			rtype="A"
			echo "found ELB $alias_dns_name in zone $alias_zone_id -> ALIAS A record"
		else
			alias_dns_name=""
			alias_zone_id=""
			echo "::warning title=route53-upsert::could not resolve '$addr' to an ELB in this account (missing elasticloadbalancing:DescribeLoadBalancers, or the LB lives elsewhere). Falling back to CNAME."
		fi
	fi
fi

# ---------------------------------------------------------------------------
# Remove any existing record at this name whose type conflicts with the one we
# are about to write. Route53 rejects an UPSERT of a CNAME where an A exists (and
# vice versa), which happens whenever the cluster's LB implementation changes
# between an IP and a hostname.
# ---------------------------------------------------------------------------
existing="$(
	aws route53 list-resource-record-sets \
		--hosted-zone-id "$zone_id" \
		--start-record-name "${fqdn}." \
		--max-items 20 \
		--output json
)"

conflicts="$(
	printf '%s' "$existing" | jq -c --arg n "${fqdn}." --arg t "$rtype" \
		'[.ResourceRecordSets[] | select(.Name == $n) | select(.Type == "A" or .Type == "AAAA" or .Type == "CNAME") | select(.Type != $t)]'
)"

if [ "$(printf '%s' "$conflicts" | jq 'length')" -gt 0 ]; then
	echo "deleting conflicting record(s) at ${fqdn}: $(printf '%s' "$conflicts" | jq -r '[.[].Type] | join(",")')"
	printf '%s' "$conflicts" |
		jq '{Comment: "teleport-ci: remove conflicting record type", Changes: [.[] | {Action: "DELETE", ResourceRecordSet: .}]}' \
			>"$workdir/delete.json"
	aws route53 change-resource-record-sets \
		--hosted-zone-id "$zone_id" \
		--change-batch "file://$workdir/delete.json" \
		--output text --query 'ChangeInfo.Id' >"$workdir/change-id"
	aws route53 wait resource-record-sets-changed --id "$(cat "$workdir/change-id")"
fi

# ---------------------------------------------------------------------------
# UPSERT.
# ---------------------------------------------------------------------------
if [ -n "$alias_dns_name" ]; then
	jq -n \
		--arg name "$fqdn" \
		--arg dns "$alias_dns_name" \
		--arg zone "$alias_zone_id" \
		'{Comment: "teleport-ci proxy", Changes: [{Action: "UPSERT", ResourceRecordSet: {Name: $name, Type: "A", AliasTarget: {HostedZoneId: $zone, DNSName: $dns, EvaluateTargetHealth: false}}}]}' \
		>"$workdir/upsert.json"
else
	jq -n \
		--arg name "$fqdn" \
		--arg type "$rtype" \
		--argjson ttl "$ttl" \
		--arg value "$addr" \
		'{Comment: "teleport-ci proxy", Changes: [{Action: "UPSERT", ResourceRecordSet: {Name: $name, Type: $type, TTL: $ttl, ResourceRecords: [{Value: $value}]}}]}' \
		>"$workdir/upsert.json"
fi

echo "UPSERT ${fqdn} ${rtype} -> ${alias_dns_name:-$addr} (zone $zone_id)"
change_id="$(
	aws route53 change-resource-record-sets \
		--hosted-zone-id "$zone_id" \
		--change-batch "file://$workdir/upsert.json" \
		--output text --query 'ChangeInfo.Id'
)"

echo "waiting for change $change_id to propagate to all Route53 name servers"
aws route53 wait resource-record-sets-changed --id "$change_id"
echo "Route53 change $change_id is INSYNC"
