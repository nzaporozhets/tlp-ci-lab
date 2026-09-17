# Day-2 runbook

For the one-time setup, see [`bootstrap.md`](bootstrap.md).

Contents:

1. [Deploying](#1-deploying)
2. [Destroying](#2-destroying)
3. [Failure modes, in the order they actually bite](#3-failure-modes-in-the-order-they-actually-bite)
4. [Debugging recipes](#4-debugging-recipes)
5. [Routine changes](#5-routine-changes)
6. [Standing cost](#6-standing-cost)
7. [Design notes worth knowing before you change anything](#7-design-notes-worth-knowing-before-you-change-anything)

---

## 1. Deploying

`deploy.yml` runs on `workflow_dispatch` and on `push` to `main` touching
`helm/**`, `terraform/ec2-agent/**`, `teleport/**`, `scripts/**` or the workflow
itself.

```
preflight ──▶ cluster ──▶ tokens ──┬─▶ kube-agent ──┐
                                   └─▶ ec2-agent ───┴─▶ verify
```

Dispatch inputs:

| Input | Effect |
|---|---|
| `skip_kube_agent` | Skip the in-cluster agent. `verify` reports its assertion as skipped. |
| `skip_ec2_agent` | Skip Terraform entirely. Useful when iterating on the cluster. |

**Every workflow is safe to re-run at any point.** A failed deploy is fixed by
re-running it, never by manual cleanup:

* `helm upgrade --install` — converges whether or not the release exists.
* `tctl create -f` — an upsert.
* Route53 `UPSERT` — and `route53-upsert.sh` also removes a conflicting record of
  the wrong type first (which happens if the cluster's load balancer changed from
  reporting `.hostname` to `.ip`, or back).
* `terraform apply` from a saved plan.
* `kubectl apply` for the namespace and the licence secret.

`concurrency: {group: teleport-ci-env, cancel-in-progress: false}` is shared with
`destroy.yml`: the two can never interleave, and a half-applied deploy is never
cancelled.

---

## 2. Destroying

*Actions → destroy → Run workflow.*

| Input | Meaning |
|---|---|
| `confirm` | You must type `TELEPORT_CLUSTER_NAME` exactly. Checked before checkout, before any credential is touched. |
| `keep_cluster` | `true` destroys only the agents and leaves the cluster (and its DNS record and PVC) running. This is the cost lever. |
| `delete_namespaces` | Also delete the two namespaces. Off by default. |

Order (the reverse of creation): Terraform destroy → `helm uninstall
teleport-kube-agent` → Route53 `DELETE` → `helm uninstall teleport-cluster` →
delete the licence secret → **delete the PVC** → optionally delete namespaces.

> **The PVC deletion is load-bearing.** `helm uninstall` deliberately leaves the
> PVC behind. If it survives, the next deploy silently reuses the *old* cluster
> state — including the old host CA and the old cluster name — and then fails in
> ways that look nothing like the actual cause. `destroy.yml` deletes it and then
> asserts it is really gone, failing loudly if a finalizer or an attached pod is
> holding it.

A partially completed destroy can simply be re-run: each step tolerates "already
absent".

---

## 3. Failure modes, in the order they actually bite

### 3.1 ACME times out after 15 minutes

**By far the most likely cause: the `Service type: LoadBalancer` is an L7 load
balancer that terminates TLS.** Teleport's ACME uses the **TLS-ALPN-01** challenge
on port 443, answered inside the TLS handshake. If anything in front of the proxy
terminates TLS, Let's Encrypt talks to the load balancer instead of to Teleport and
the challenge can never succeed. You need an **L4 / TCP passthrough** load
balancer — NLB, classic ELB in TCP mode, MetalLB, or a cloud L4 LB.

Check what is actually on the wire:

```bash
openssl s_client -connect "$TELEPORT_CLUSTER_NAME:443" \
  -servername "$TELEPORT_CLUSTER_NAME" </dev/null 2>/dev/null |
  openssl x509 -noout -issuer -subject
```

* Issuer mentions your load balancer or an ACM certificate → L7 LB. Fix the LB.
* Issuer is the Teleport self-signed CA and stays that way → ACME is failing;
  check the proxy logs (§4.2).
* Issuer is `Let's Encrypt` → it worked.

Other causes, in order:

2. **DNS.** `dig +short "$TELEPORT_CLUSTER_NAME"` must return the load balancer.
   If the record exists in Route53 but does not resolve publicly, the parent zone's
   NS delegation is not live. preflight checks that the name is inside the zone and
   that the zone is public, but it cannot check the world's resolvers.
3. **Rate limiting.** Let's Encrypt allows 5 duplicate certificates per registered
   domain per 168 hours. Normal operation issues one certificate and reuses it
   across `helm upgrade`s (the PVC survives), but every destroy/deploy cycle
   re-issues. Set `ACME_USE_STAGING=true` while iterating.
4. **Inbound :443 blocked.** Let's Encrypt must reach the load balancer from the
   public internet. Check the LB's security group / firewall.

`wait-for-acme.sh` restarts the proxy Deployment **once**, after 5 minutes without
a valid certificate, to re-trigger Teleport's ACME loop — not on every run, and not
before DNS has had a chance to propagate.

### 3.2 The kube agent will not join

* **`ACME_USE_STAGING=true`.** The staging CA is not publicly trusted, and
  `insecureSkipProxyTLSVerify` is `false` by design. The agent *should* fail here;
  the fix is to finish the certificate, not to skip verification. Deploy with
  `skip_kube_agent: true` while running against staging.
* **ServiceAccount mismatch.** The token's
  `spec.kubernetes.allow[].service_account` must equal
  `"<namespace>:<the chart's ServiceAccount name>"`. Both `lint.yml` and the
  `kube-agent` job cross-check this against `helm template`, so a chart bump is
  caught on the PR — but if you have edited either file by hand, check them.
* **`teleportClusterName` unset.** Required whenever `joinParams.method` is
  `kubernetes`: it is what makes the chart mount a projected ServiceAccount token.
  It is set in `helm/teleport-kube-agent.values.yaml`; do not remove it.
* Auth-side rejection shows up in the auth log:

```bash
kubectl -n "$K8S_NAMESPACE_CLUSTER" logs -l app.kubernetes.io/component=auth \
  -c teleport --tail=200 | grep -i 'join\|token\|serviceaccount'
```

### 3.3 The EC2 agent does not appear in `tctl nodes ls`

1. **ARN mismatch.** Compare the Terraform output with the token:

   ```bash
   terraform -chdir=terraform/ec2-agent output -raw expected_join_arn
   K8S_NAMESPACE_CLUSTER=teleport ./scripts/tctl.sh get token/ec2-agent-token
   ```

   Note that a role's **path is not part of an `sts` assumed-role ARN** — the ARN
   is `arn:aws:sts::<account>:assumed-role/<RoleName>/<instance-id>`, with no
   `/teleport-ci/`. If you changed `EC2_AGENT_ROLE_NAME`, re-run the `tokens` job.
2. **user-data failed.** Read the console log:

   ```bash
   aws ec2 get-console-output --instance-id i-… --latest --output text | tail -n 120
   ```

   Look for `TELEPORT_BOOTSTRAP_OK` or `TELEPORT_BOOTSTRAP_FAILED rc=…`. The
   sentinel file on the instance is `/var/lib/teleport-bootstrap/complete`:
   absent = user-data still running, `failed rc=N` = it failed, `ok` = it finished.
3. **No outbound internet.** The node must reach the proxy on :443, `sts.<region>`
   and the package repositories. There are no inbound rules and no key pair by
   design, so a subnet without NAT produces a node that installs nothing.
4. **Version skew.** Agents must never be newer than the Auth Service. Both come
   from `TELEPORT_VERSION`, so this only happens if you changed one by hand.

### 3.4 `preflight` fails on RBAC

The output lists exactly which `verb resource (namespace)` triples were denied.
Compare against the manifests in `bootstrap.md` §3.3. `pods/exec` in the cluster
namespace is the one people miss — it is how `tctl` is invoked.

### 3.5 `setup-tools` fails: runner tooling drift

The composite action **verifies and never installs**. A failure means the runner
has drifted from `tool-versions.env`. Either:

* re-provision the runner (`terraform apply` in `terraform/runner-bootstrap` after
  a `terraform taint aws_instance.runner`, or just change `user_data` — the
  instance is replaced on user-data change), or
* fix it in place over SSM and record what you did.

Do **not** make the action install tools: that would let a workflow mutate the
persistent runner.

### 3.6 Terraform state lock is stuck

The S3 backend's native lock is an object at
`s3://$TF_STATE_BUCKET/teleport-ci/ec2-agent.tfstate.tflock`. If a run was killed
mid-apply:

```bash
aws s3 ls "s3://$TF_STATE_BUCKET/teleport-ci/"
aws s3 rm  "s3://$TF_STATE_BUCKET/teleport-ci/ec2-agent.tfstate.tflock"
```

Make sure no run is in flight first — `concurrency` should already guarantee that.

### 3.7 The kubeconfig token expired

`preflight` fails with an authentication error from the API server. Re-issue the
ServiceAccount token (`bootstrap.md` §3.3) and update the `KUBECONFIG` environment
secret.

---

## 4. Debugging recipes

All of these run on the runner (over SSM) from a checkout of this repo, with
`KUBECONFIG` pointing at a kubeconfig for the cluster.

### 4.1 Run `tctl`

```bash
export K8S_NAMESPACE_CLUSTER=teleport
./scripts/tctl.sh status
./scripts/tctl.sh get nodes --format=json | jq '.[].spec.hostname'
./scripts/tctl.sh get kube_servers --format=json | jq '.[].spec.cluster.metadata.name'
./scripts/tctl.sh get tokens
./scripts/tctl.sh users add admin --roles=editor,access,auditor
```

`tctl.sh` resolves the auth Deployment by label selector
(`app.kubernetes.io/name=teleport-cluster,app.kubernetes.io/component=auth`), so a
chart bump that renames it does not break this. Override with
`TCTL_AUTH_WORKLOAD=deploy/some-name` if you need to.

### 4.2 Logs

```bash
kubectl -n teleport logs -l app.kubernetes.io/component=auth  -c teleport --tail=200
kubectl -n teleport logs -l app.kubernetes.io/component=proxy -c teleport --tail=200
kubectl -n teleport-agent logs -l app.kubernetes.io/name=teleport-kube-agent -c teleport --tail=200
```

Logs are JSON (`log.format: json` in the values), so:

```bash
kubectl -n teleport logs -l app.kubernetes.io/component=proxy -c teleport --tail=500 |
  jq -r 'select(.component // "" | test("ACME|TLS"; "i")) | "\(.timestamp) \(.message)"'
```

### 4.3 Artifacts from a failed run

Every job uploads a diagnostics artifact on failure: `kubectl get all,pvc,events`,
`kubectl logs --tail=200` for the auth, proxy and agent pods, `kubectl describe`
for non-Ready pods, `helm status`, `terraform show`, the Terraform plan, and for
the EC2 agent the serial console output. Download them from the run page rather
than reproducing the failure by hand.

### 4.4 The Terraform plan

Every run uploads `tfplan` plus a human-readable `tfplan.txt`, retained for 14
days, for auditability. A no-change deploy should show an empty plan — that is
acceptance criterion 3.

---

## 5. Routine changes

### 5.1 Bumping Teleport

1. Change the `TELEPORT_VERSION` repository variable.
2. Run `deploy.yml`.

One variable drives the cluster chart, the agent chart and the EC2 package, so
they cannot drift. `verify.yml` asserts the running versions match. Bump one minor
at a time and read Teleport's upgrade notes; the EC2 instance is **replaced**
(user-data changes), the Helm releases are upgraded in place.

### 5.2 Bumping the runner's tooling

Edit `tool-versions.env` and re-apply `terraform/runner-bootstrap`. That file is
the single source of truth: `runner-bootstrap` parses it to build user-data, and
`setup-tools` asserts against it at the start of every job. Keep kubectl within
one minor of the target cluster.

### 5.3 Changing the cluster name

You cannot. `clusterName` is baked into the host CAs and every issued certificate.
Run `destroy.yml` (with `keep_cluster: false`, so the PVC goes), change the
variable, and deploy again.

### 5.4 Changing the Teleport labels on the EC2 node

`teleport_labels` in `terraform/ec2-agent`. Keep `managed-by = github-actions`:
`scripts/verify.sh` asserts it, and the runner's IAM policy conditions mutating
EC2 actions on the matching `ManagedBy` tag.

### 5.5 Switching to a Route53 ALIAS record

`route53-upsert.sh` writes a `CNAME` for a load balancer hostname by default. Set
`ROUTE53_USE_ALIAS=true` to make it look the hostname up in
`elbv2 describe-load-balancers` / `elb describe-load-balancers` and write an ALIAS
`A` record instead. This needs `elasticloadbalancing:DescribeLoadBalancers`, which
the runner role does **not** grant by default; without it the script warns and
falls back to a CNAME.

---

## 6. Standing cost

The environment is **persistent** — it stays up until you destroy it. Rough
on-demand figures (eu-west-1, mid-2026; check current pricing):

| Item | Approx. monthly |
|---|---|
| Runner `t3.small`, 30 GiB gp3 | ~$18 + ~$3 |
| Agent `t3.micro`, 20 GiB gp3 | ~$9 + ~$2 |
| Network Load Balancer for the proxy Service | ~$18 + LCU |
| 10 GiB PVC for Teleport state | ~$1 |
| Route53 hosted zone | $0.50 |
| S3 state, SSM, data transfer | cents |

So of the order of **$50/month**, dominated by the two instances and the load
balancer. Notes:

* `destroy.yml` with `keep_cluster: true` drops the agent instance (~$11/month)
  while keeping the cluster reachable. This is the cheap lever between demos.
* A full `destroy.yml` leaves only the hosted zone, the state bucket and the runner
  standing. The **runner is not managed by `destroy.yml`** — it is bootstrap
  infrastructure. Stop or terminate it separately if you want to stop paying for
  it, and remember that terminating it means re-running the bootstrap.
* A full destroy/deploy cycle re-issues a Let's Encrypt certificate. Five per
  registered domain per 168 hours.

---

## 7. Design notes worth knowing before you change anything

**Why the kube agent uses the `kubernetes` join method and not `iam`.** The
Kubernetes cluster is not assumed to be EKS. Nothing in the Kubernetes path may
depend on AWS. With `kubernetes` / `in_cluster`, the Auth Service validates the
agent's ServiceAccount JWT against the Kubernetes API directly — there is no
shared secret anywhere, which is why the token YAML files live in git in
plaintext.

**Why `insecureSkipProxyTLSVerify` must stay `false`.** If the agent cannot verify
the proxy certificate, ACME has not completed. Skipping verification would convert
a loud, diagnosable failure into a silently insecure deployment.

**Why `highAvailability.replicaCount` is 1.** ACME in the `teleport-cluster` chart
is single-pod only: the challenge state is not shared between replicas. Raising it
requires switching to an externally managed certificate.

**Why `helm install` happens before the DNS record exists.** ACME cannot complete
until DNS resolves to the load balancer, but the load balancer address is only
known once Helm has created the Service. So the proxy first comes up with a
self-signed certificate, then DNS is written, then Teleport's ACME retry loop picks
up the now-resolvable name. No pod restart should be needed;
`wait-for-acme.sh` performs one, once, only as a fallback.

**Why nothing runs `tsh login`.** All verification goes through `tctl` inside the
auth pod, so no Teleport user credentials exist anywhere in CI. The cost is that
this is a server-side check, not a true client-side one; add a Machine ID / `tbot`
join if you later want the latter.

**Why `setup-tools` only verifies.** The runner is persistent and shared between
runs. A workflow that installs tools into it is a workflow that can silently change
the behaviour of every later run.

**Why the licence and kubeconfig are files under `$RUNNER_TEMP` at mode 0600, and
why every job has an `always()` cleanup step.** On a persistent self-hosted runner
`$RUNNER_TEMP` is **not** wiped between runs. Neither value is ever echoed or
passed as a command-line argument (arguments are visible in `ps` to every other
process on the box).
