# Spec: GitHub Actions deployment of a Teleport cluster and two agents

**Status:** ready for implementation
**Date:** 2026-09-17
**Target Teleport / chart version:** `18.11.1` (latest published on `charts.releases.teleport.dev` at time of writing)

---

## 1. Goal

Build a GitHub repository that, via GitHub Actions, deploys and manages:

1. **A Teleport Enterprise cluster** on an existing Kubernetes cluster, using the official
   `teleport-cluster` Helm chart, with a real public hostname (Route53) and a Let's Encrypt
   certificate (ACME).
2. **A Teleport Agent on Kubernetes**, using the official `teleport-kube-agent` Helm chart,
   joining with the `kubernetes` (in-cluster) join method — enrolls the cluster for
   `tsh kube` access.
3. **A Teleport Agent on an EC2 node**, provisioned by Terraform, joining with the `iam`
   join method — enrolls the node for `tsh ssh` access.

The environment is **persistent**: a deploy workflow brings it up and leaves it running; a
separate, manually-triggered destroy workflow tears it down.

## 2. Decisions (confirmed with the operator)

| Question | Decision |
|---|---|
| Where does the Kubernetes cluster come from? | **Pre-existing cluster**, reached via a `KUBECONFIG` repo secret. Cluster lifecycle is out of scope. |
| How does the runner get cloud credentials? | **Self-hosted EC2 runner with an IAM instance profile.** No AWS keys in GitHub secrets. A one-time bootstrap (§7) creates it. |
| Teleport edition and TLS? | **Enterprise** (license supplied as a secret) + **Route53** DNS + **ACME / Let's Encrypt**. |
| Lifecycle? | **Persistent environment + separate destroy workflow.** |

### 2.1 Consequences of these decisions that the implementation must respect

- The Kubernetes cluster is **not assumed to be EKS**. Nothing in the K8s path may depend on
  AWS. This is why the kube agent uses the `kubernetes` in-cluster join method rather than
  `iam`, and why the kubeconfig arrives as a secret rather than from `aws eks update-kubeconfig`.
- The runner's IAM role is used **only** for the EC2 agent, Route53, and Terraform state —
  not for Kubernetes.
- `clusterName` in the `teleport-cluster` chart **cannot be changed for the life of the
  cluster.** It is therefore a repo *variable*, not a per-run input, and the destroy workflow
  is the only way to change it.
- ACME in the `teleport-cluster` chart is **single-pod only**. `highAvailability.replicaCount`
  stays at `1`.

## 3. Architecture

```
                    GitHub Actions
                          │
                          ▼
        ┌────────────────────────────────────┐
        │  Self-hosted runner (EC2)          │
        │  labels: self-hosted, teleport-ci  │
        │  IAM instance profile (no secrets) │
        │  tools: kubectl helm terraform aws │
        └───────┬──────────────────┬─────────┘
                │                  │
   KUBECONFIG   │                  │  IAM role
   (repo secret)│                  │
                ▼                  ▼
   ┌──────────────────────┐   ┌──────────────────────────┐
   │ Kubernetes cluster   │   │ AWS                      │
   │                      │   │                          │
   │ ns: teleport         │   │  Route53 hosted zone     │
   │  teleport-cluster    │◀──┼─ A/ALIAS → Service LB    │
   │  (Enterprise, ACME)  │   │                          │
   │  Service LoadBalancer│   │  EC2 agent instance      │
   │                      │   │   + no-op instance profile│
   │ ns: teleport-agent   │   │   joins via `iam` method ─┼──┐
   │  teleport-kube-agent │   │                          │  │
   │  joins via           │   │  S3 + lock (TF state)    │  │
   │  `kubernetes` method │   └──────────────────────────┘  │
   │        │             │                                 │
   │        └─────────────┴──── joins ───▶ Proxy :443 ◀──────┘
   └──────────────────────┘
```

### 3.1 Join methods — and why

| Agent | Join method | Rationale |
|---|---|---|
| Kubernetes agent | `kubernetes`, `type: in_cluster` | Agent runs in the same cluster as the Auth Service, so Auth validates the agent's ServiceAccount JWT directly. **No shared secret exists at all.** Token name is not sensitive. |
| EC2 agent | `iam` | Node proves its identity by signing an `sts:GetCallerIdentity` request. **No shared secret.** Token name is not sensitive. Restricted by `aws_account` + `aws_arn`. |

Static/secret join tokens are explicitly **not** used. This removes the whole class of
"token leaked in workflow logs" failures and means the token YAML files can live in the repo
in plaintext.

## 4. Repository layout

```
.
├── .github/
│   ├── workflows/
│   │   ├── deploy.yml            # main entrypoint (workflow_dispatch + push to main)
│   │   ├── destroy.yml           # manual teardown, requires typed confirmation
│   │   ├── verify.yml            # reusable: asserts cluster + both agents are healthy
│   │   └── lint.yml              # runs on PRs; GitHub-hosted runner only (see §10.1)
│   └── actions/
│       └── setup-tools/
│           └── action.yml        # pins + verifies kubectl/helm/terraform/aws/tctl versions
├── helm/
│   ├── teleport-cluster.values.yaml      # envsubst-templated
│   └── teleport-kube-agent.values.yaml   # envsubst-templated
├── teleport/
│   └── tokens/
│       ├── kube-agent-token.yaml
│       └── ec2-agent-token.yaml
├── terraform/
│   ├── ec2-agent/               # applied by deploy.yml
│   │   ├── main.tf  variables.tf  outputs.tf  backend.tf  versions.tf
│   │   └── user-data.sh.tftpl
│   └── runner-bootstrap/        # applied ONCE, by hand (§7)
│       ├── main.tf  variables.tf  outputs.tf  versions.tf
│       └── user-data.sh.tftpl
├── scripts/
│   ├── kubeconfig.sh            # materialise KUBECONFIG secret to a 0600 temp file
│   ├── route53-upsert.sh        # point the DNS name at the Service LoadBalancer
│   ├── route53-delete.sh
│   ├── tctl.sh                  # run tctl inside the auth pod via kubectl exec
│   ├── wait-for-acme.sh         # poll until the proxy serves a valid LE cert
│   └── verify.sh                # the assertions used by verify.yml
├── docs/
│   ├── bootstrap.md             # one-time setup runbook (§7, §8)
│   └── runbook.md               # day-2: how to deploy, destroy, debug
└── README.md
```

## 5. Configuration surface

### 5.1 Repository *variables* (`vars.*`, non-secret)

| Name | Example | Purpose |
|---|---|---|
| `TELEPORT_VERSION` | `18.11.1` | Chart version *and* `--version` for both Helm releases, and the agent package version on EC2. Single source of truth. |
| `TELEPORT_CLUSTER_NAME` | `teleport.ci.example.com` | Chart `clusterName` + proxy public address. **Immutable.** |
| `ACME_EMAIL` | `infra@example.com` | Let's Encrypt registration contact. |
| `ACME_USE_STAGING` | `false` | When `true`, sets `acmeURI` to the LE staging directory. See §9.3. |
| `AWS_REGION` | `eu-west-1` | Region for the EC2 agent and TF state. |
| `ROUTE53_ZONE_ID` | `Z0123456789ABCDEFGHIJ` | Hosted zone containing `TELEPORT_CLUSTER_NAME`. |
| `TF_STATE_BUCKET` | `example-teleport-ci-tfstate` | S3 bucket for Terraform state. |
| `EC2_AGENT_INSTANCE_TYPE` | `t3.micro` | Agent node size. |
| `EC2_AGENT_SUBNET_ID` | `subnet-…` | Subnet with outbound internet (needs to reach the proxy + package repos). |
| `EC2_AGENT_VPC_ID` | `vpc-…` | For the agent's security group. |
| `K8S_NAMESPACE_CLUSTER` | `teleport` | Namespace for `teleport-cluster`. |
| `K8S_NAMESPACE_AGENT` | `teleport-agent` | Namespace for `teleport-kube-agent`. |
| `KUBE_CLUSTER_NAME` | `ci-k8s` | Display name of the enrolled Kubernetes cluster in Teleport. |
| `RUNNER_LABEL` | `teleport-ci` | Self-hosted runner label. |

### 5.2 Repository *secrets*

| Name | Contents |
|---|---|
| `KUBECONFIG` | Base64-encoded kubeconfig for the target cluster, scoped to a ServiceAccount with only the permissions in §8.2. **Not** a cluster-admin user cert. |
| `TELEPORT_ENTERPRISE_LICENSE` | Contents of `license.pem`. |

That is the **entire** secret surface. No AWS credentials, no join tokens.

### 5.3 GitHub Environment

All deploy/destroy jobs run in a GitHub Environment named `teleport-ci` holding the above
secrets. Recommended protection rules:

- **Required reviewers** on `destroy.yml` (and optionally on `deploy.yml`).
- Deployment branch rule: `main` only.

## 6. Workflows

### 6.1 `deploy.yml`

**Triggers**

```yaml
on:
  workflow_dispatch:
    inputs:
      skip_ec2_agent:   { type: boolean, default: false }
      skip_kube_agent:  { type: boolean, default: false }
  push:
    branches: [main]
    paths: ['helm/**', 'terraform/ec2-agent/**', 'teleport/**', 'scripts/**', '.github/workflows/deploy.yml']
```

**Never** `pull_request` — see §10.1.

**Top-level**

```yaml
concurrency:
  group: teleport-ci-env      # shared with destroy.yml
  cancel-in-progress: false   # never cancel a half-applied deploy
permissions:
  contents: read
defaults:
  run: { shell: bash }
env:
  # promote vars.* into env so scripts and envsubst templates can read them
```

All jobs: `runs-on: [self-hosted, linux, x64, "${{ vars.RUNNER_LABEL }}"]`,
`environment: teleport-ci`, and `timeout-minutes` set on every job.

**Job graph**

```
preflight ──▶ cluster ──▶ tokens ──┬─▶ kube-agent ──┐
                                   └─▶ ec2-agent ───┴─▶ verify
```

---

**Job `preflight`** (timeout 5m)

1. `actions/checkout@v4`.
2. `./.github/actions/setup-tools` — assert pinned tool versions are present on the runner
   (do **not** install into the runner on every run; a self-hosted runner is provisioned with
   them in §7 and this action only *verifies*, failing with a clear message if a tool is
   missing or the wrong major version).
3. `aws sts get-caller-identity` — proves the instance profile works; export
   `AWS_ACCOUNT_ID` to `$GITHUB_OUTPUT`.
4. `scripts/kubeconfig.sh` → decode `secrets.KUBECONFIG` into `$RUNNER_TEMP/kubeconfig`
   (mode `0600`), `kubectl version --short`, `kubectl auth can-i` spot-checks for the verbs
   in §8.2. **Fail fast with a readable message** rather than letting Helm fail obscurely.
5. Assert `TELEPORT_CLUSTER_NAME` is a subdomain of the zone named by `ROUTE53_ZONE_ID`
   (`aws route53 get-hosted-zone`). A mismatch here otherwise surfaces as an unexplained
   ACME timeout 15 minutes later.
6. Assert the S3 state bucket exists and versioning is enabled.

**Job `cluster`** (timeout 25m)

1. `helm repo add teleport https://charts.releases.teleport.dev && helm repo update`.
2. Create namespace `K8S_NAMESPACE_CLUSTER` if absent (`kubectl create ns --dry-run=client -o yaml | kubectl apply -f -`).
3. Create/update the license secret **without echoing it**:
   ```bash
   printf '%s' "$TELEPORT_ENTERPRISE_LICENSE" > "$RUNNER_TEMP/license.pem"
   kubectl -n "$K8S_NAMESPACE_CLUSTER" create secret generic license \
     --from-file=license.pem="$RUNNER_TEMP/license.pem" \
     --dry-run=client -o yaml | kubectl apply -f -
   ```
   The key inside the secret **must** be `license.pem`.
4. `envsubst < helm/teleport-cluster.values.yaml > "$RUNNER_TEMP/cluster-values.yaml"`.
5. `helm upgrade --install teleport-cluster teleport/teleport-cluster --version "$TELEPORT_VERSION" -n "$K8S_NAMESPACE_CLUSTER" -f "$RUNNER_TEMP/cluster-values.yaml" --wait --timeout 10m`.
   - Idempotent by construction; safe to re-run.
6. **DNS step.** Poll for the `teleport-cluster` Service's external address
   (`.status.loadBalancer.ingress[0].hostname` *or* `.ip` — handle both) for up to 5 min,
   then `scripts/route53-upsert.sh`:
   - hostname → `CNAME` (or ALIAS if the LB is a known AWS ELB in the same account)
   - IP → `A`
   - TTL 60, `UPSERT`, then `aws route53 wait resource-record-sets-changed`.
7. `scripts/wait-for-acme.sh` — poll `https://$TELEPORT_CLUSTER_NAME/webapi/ping` with strict
   cert verification until it returns 200, up to 15 min, logging the observed issuer each
   attempt. Print the pod's recent logs on timeout.
8. Emit `proxy_addr=$TELEPORT_CLUSTER_NAME:443` as a job output.

> **Ordering note for the implementer:** ACME cannot succeed until DNS resolves to the load
> balancer, but the load balancer address is only known after Helm installs. So step 5 will
> complete with a *self-signed* cert, steps 6–7 then let Teleport's ACME retry loop pick up
> the now-resolvable name. No pod restart should be needed; if the implementation finds one is,
> `kubectl rollout restart` the proxy deployment inside `wait-for-acme.sh` rather than
> unconditionally.

**Job `tokens`** (timeout 5m)

Apply both provision tokens through `scripts/tctl.sh`, which shells into the auth pod:

```bash
kubectl -n "$K8S_NAMESPACE_CLUSTER" exec -i deploy/teleport-cluster-auth -- tctl create -f /dev/stdin < "$1"
```

(Implementer: confirm the auth workload's actual name for the chart version in use — in
`standalone` mode it is the `teleport-cluster-auth` Deployment. Resolve it by label selector
rather than hardcoding, so a chart bump doesn't break this.)

Use `tctl create -f` (upsert) so re-runs are idempotent.

`teleport/tokens/kube-agent-token.yaml`:

```yaml
kind: token
version: v2
metadata:
  name: kube-agent-token
  expires: "2050-01-01T00:00:00Z"
spec:
  roles: [Kube]
  join_method: kubernetes
  kubernetes:
    type: in_cluster
    allow:
      # "namespace:serviceaccountname" — must match the chart's SA
      - service_account: "${K8S_NAMESPACE_AGENT}:teleport-kube-agent"
```

`teleport/tokens/ec2-agent-token.yaml`:

```yaml
kind: token
version: v2
metadata:
  name: ec2-agent-token
spec:
  roles: [Node]
  join_method: iam
  allow:
    - aws_account: "${AWS_ACCOUNT_ID}"
      aws_arn: "arn:aws:sts::${AWS_ACCOUNT_ID}:assumed-role/${EC2_AGENT_ROLE_NAME}/i-*"
```

Both token names are non-secret by design (see §3.1). Both files are `envsubst`-templated.

**Job `kube-agent`** (timeout 15m, `if: !inputs.skip_kube_agent`)

```yaml
# helm/teleport-kube-agent.values.yaml
proxyAddr: "${TELEPORT_CLUSTER_NAME}:443"
roles: kube
kubeClusterName: "${KUBE_CLUSTER_NAME}"
enterprise: true
joinParams:
  method: kubernetes
  tokenName: kube-agent-token
teleportClusterName: "${TELEPORT_CLUSTER_NAME}"
highAvailability:
  replicaCount: 1
```

`helm upgrade --install teleport-kube-agent teleport/teleport-kube-agent --version "$TELEPORT_VERSION" -n "$K8S_NAMESPACE_AGENT" --create-namespace -f … --wait --timeout 5m`

- `insecureSkipProxyTLSVerify` **must stay `false`.** If the agent cannot verify the proxy,
  that means ACME did not complete and the correct fix is to fail the run.
- The chart's ServiceAccount name must match the token's `allow.service_account`. Verify with
  `helm template` in `lint.yml` so a mismatch is caught on PR, not at deploy time.

**Job `ec2-agent`** (timeout 20m, `if: !inputs.skip_ec2_agent`)

`terraform/ec2-agent/` creates:

- An IAM role `${EC2_AGENT_ROLE_NAME}` with **no policies attached** (a "no-op" role — its
  only purpose is to give the instance an ARN that the join token can match) and an instance
  profile containing it.
- A security group: **no inbound rules**, egress `0.0.0.0/0`. Teleport agents dial *out* to
  the proxy; nothing needs to reach the node. No SSH port, no key pair — access is via
  Teleport once joined, which is the point of the exercise.
- An EC2 instance in `EC2_AGENT_SUBNET_ID` from the latest Amazon Linux 2023 AMI resolved via
  the SSM public parameter (`/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64`),
  with IMDSv2 required (`http_tokens = "required"`) and `user-data.sh.tftpl`.
- Tags including `Name`, `ManagedBy = github-actions`, and the workflow run URL.

`user-data.sh.tftpl` must:

1. Install Teleport at the pinned version via the official one-line installer, passing the
   version explicitly so the node never drifts ahead of the auth service.
2. Write `/etc/teleport.yaml`:
   ```yaml
   version: v3
   teleport:
     join_params:
       token_name: ec2-agent-token
       method: iam
     proxy_server: ${proxy_addr}
   ssh_service:
     enabled: true
     labels:
       env: ci
       managed-by: github-actions
   auth_service:
     enabled: false
   proxy_service:
     enabled: false
   ```
3. `systemctl enable --now teleport`.
4. Write a completion sentinel so the workflow can distinguish "user-data still running" from
   "user-data failed".

Terraform invocation:

- Backend: S3, `key = "teleport-ci/ec2-agent.tfstate"`, `use_lockfile = true` (native S3
  locking, Terraform ≥ 1.10 — no DynamoDB table needed).
- `terraform init -input=false`, `fmt -check`, `validate`, `plan -out=tfplan -detailed-exitcode`,
  then `apply -input=false tfplan`.
- Upload the plan as an artifact for auditability.
- Pass `proxy_addr` from the `cluster` job output; pass `teleport_version` from
  `vars.TELEPORT_VERSION`.

**Job `verify`** (timeout 10m, `needs: [kube-agent, ec2-agent]`, `if: always()` guarded so it
still runs when an agent job was intentionally skipped)

Calls the reusable `verify.yml`. Assertions, all via `scripts/tctl.sh` (no `tsh login`, so no
user credentials are needed anywhere):

1. `tctl status` succeeds and reports the expected cluster name and version.
2. The proxy serves a **publicly trusted** cert:
   `curl --fail --show-error https://$TELEPORT_CLUSTER_NAME/webapi/ping` with default CA bundle,
   and the JSON `server_version` matches `TELEPORT_VERSION`.
3. `tctl get kube_servers --format=json | jq -e '…'` contains `KUBE_CLUSTER_NAME`.
4. `tctl nodes ls --format=json | jq -e '…'` contains a node whose hostname/`instance-id`
   matches the Terraform-created instance ID, with label `managed-by=github-actions`.
5. Each of 3 and 4 polls with backoff for up to 5 min — agents take tens of seconds to appear.
6. Write a `$GITHUB_STEP_SUMMARY` table: cluster URL, version, kube cluster name, node ID,
   ACME issuer.

### 6.2 `destroy.yml`

```yaml
on:
  workflow_dispatch:
    inputs:
      confirm:
        description: 'Type the cluster name to confirm destruction'
        required: true
      keep_cluster:
        description: 'Destroy agents only, leave the Teleport cluster running'
        type: boolean
        default: false
concurrency:
  group: teleport-ci-env
  cancel-in-progress: false
```

Steps, in this order (reverse of creation):

1. **Guard:** fail immediately unless `inputs.confirm == vars.TELEPORT_CLUSTER_NAME`.
2. `terraform destroy -auto-approve` in `terraform/ec2-agent/`.
3. `helm uninstall teleport-kube-agent -n "$K8S_NAMESPACE_AGENT" --ignore-not-found`.
4. If `keep_cluster` is false:
   - `scripts/route53-delete.sh` (DELETE the record set; must read the *current* value from
     Route53 to build a valid DELETE change batch, and tolerate "already absent").
   - `helm uninstall teleport-cluster -n "$K8S_NAMESPACE_CLUSTER" --ignore-not-found`.
   - Delete the `license` secret.
   - **Delete the PVC.** `helm uninstall` leaves it behind, and a later deploy would silently
     reuse the old cluster state and CA. Deleting it is what makes the next deploy clean.
   - Optionally delete the namespaces.
5. Every step uses `continue-on-error: false` but is individually idempotent, so a partially
   completed destroy can simply be re-run.

### 6.3 `lint.yml` (PR gate, GitHub-hosted runner)

Runs on `pull_request`, on `ubuntu-latest`, with **no access to the `teleport-ci` environment
and no secrets**:

- `helm lint` + `helm template` both charts with a fixture values file; assert the rendered
  kube-agent ServiceAccount name equals the name in `kube-agent-token.yaml`.
- `terraform fmt -check -recursive`, `terraform validate` (with a stub backend).
- `actionlint`, `shellcheck` on `scripts/**`, `yamllint`.
- Assert no workflow that uses the `teleport-ci` environment is triggered by `pull_request`.

## 7. Self-hosted runner spec (`terraform/runner-bootstrap/`)

Applied **once, by hand, from the operator's machine** with credentials that GitHub never
sees. Documented in `docs/bootstrap.md`.

### 7.1 Compute

- EC2, Amazon Linux 2023, `t3.small` (2 vCPU / 2 GiB is enough; Helm + Terraform are light),
  30 GiB gp3 root volume.
- Private subnet + NAT, or public subnet with **no inbound rules at all**. The runner makes
  only outbound connections (GitHub, the K8s API endpoint, AWS APIs, package repos).
  Administrative access via SSM Session Manager, not SSH.
- IMDSv2 required. Detailed monitoring off. `Name` tag `github-runner-teleport-ci`.

### 7.2 IAM role for the runner (least privilege)

Attached policies, each scoped:

| Purpose | Actions | Resource scope |
|---|---|---|
| Identity check | `sts:GetCallerIdentity` | `*` (no resource form) |
| Terraform state | `s3:GetObject`, `PutObject`, `DeleteObject`, `ListBucket` | the state bucket + `teleport-ci/*` prefix only |
| DNS | `route53:ChangeResourceRecordSets`, `ListResourceRecordSets`, `GetHostedZone` | `arn:aws:route53:::hostedzone/${ROUTE53_ZONE_ID}` only |
| DNS change polling | `route53:GetChange` | `*` (required; not resource-scopable) |
| AMI lookup | `ssm:GetParameter` | `arn:aws:ssm:*::parameter/aws/service/ami-amazon-linux-latest/*` |
| EC2 agent lifecycle | `ec2:RunInstances`, `TerminateInstances`, `Describe*`, `CreateTags`, `Create/DeleteSecurityGroup`, `AuthorizeSecurityGroupEgress`, `ModifyInstanceMetadataOptions` | Region-conditioned; mutating actions further conditioned on `aws:ResourceTag/ManagedBy = github-actions` where the API supports it |
| Agent role management | `iam:CreateRole`, `DeleteRole`, `GetRole`, `TagRole`, `CreateInstanceProfile`, `DeleteInstanceProfile`, `AddRoleToInstanceProfile`, `RemoveRoleFromInstanceProfile`, `GetInstanceProfile` | **Path-scoped:** `arn:aws:iam::*:role/teleport-ci/*` and `.../instance-profile/teleport-ci/*` |
| Pass the agent role | `iam:PassRole` | `arn:aws:iam::*:role/teleport-ci/*`, with `Condition: StringEquals: {iam:PassedToService: ec2.amazonaws.com}` |
| SSM admin access | `AmazonSSMManagedInstanceCore` (managed) | — |

> **Implementer: the `iam:*` + `PassRole` grant is the sharpest edge here.** Anyone who can
> run a workflow on this runner can create a role under `/teleport-ci/` and attach it to an
> instance. Path-scoping plus `PassRole` conditions keeps that from becoming privilege
> escalation, and the role must have **no** `iam:AttachRolePolicy` or `iam:PutRolePolicy`
> permission — that is what prevents a created role from being granted anything. Call this out
> in `docs/bootstrap.md`.

### 7.3 Runner software (`user-data.sh.tftpl`)

Installs, at pinned versions recorded in one place so `setup-tools/action.yml` can assert them:

- `kubectl` (matching the target cluster's minor version ±1)
- `helm` 3.x
- `terraform` ≥ 1.10 (needed for S3 native locking)
- `awscli` v2
- `jq`, `gettext` (`envsubst`), `git`, `curl`
- Teleport client tools (`tsh`, `tctl`) at `TELEPORT_VERSION` — optional, since `tctl` runs in
  the auth pod, but useful for manual debugging

Then registers the runner:

- Non-ephemeral, single runner, installed as a systemd service running as a **non-root
  `runner` user**.
- Registration uses a **GitHub App** (app ID + installation ID + private key placed on the
  instance by the bootstrap, or fetched from SSM Parameter Store) to mint a short-lived
  registration token at boot. A classic PAT is acceptable but should be `repo`-scoped and
  noted as the weaker option.
- Labels: `self-hosted,linux,x64,${RUNNER_LABEL}`.
- `--unattended --replace` so a reboot re-registers cleanly.

### 7.4 Runner outputs

`terraform output` prints the instance ID, the role ARN, and a reminder of the repo
variables/secrets to set. `docs/bootstrap.md` walks through it end to end.

## 8. Prerequisites the operator must satisfy before the first deploy

### 8.1 AWS
- A Route53 public hosted zone for the parent domain of `TELEPORT_CLUSTER_NAME`, with NS
  delegation actually working (ACME will fail otherwise).
- An S3 bucket for Terraform state, **versioning enabled**, public access blocked.
- A VPC with a subnet that has outbound internet, for the agent and the runner.

### 8.2 Kubernetes
- A cluster whose `Service type: LoadBalancer` provisions an **L4 / TCP passthrough**
  load balancer. Teleport's ACME uses the **TLS-ALPN-01** challenge on port 443, so an L7
  load balancer that terminates TLS will make ACME fail. This is the single most likely
  cause of a failed first deploy — `docs/runbook.md` must say so explicitly.
- A `StorageClass` capable of provisioning a 10 GiB `ReadWriteOnce` PVC.
- A ServiceAccount for CI, with a kubeconfig exported into the `KUBECONFIG` secret. It needs,
  in the two Teleport namespaces: full CRUD on `deployments`, `statefulsets`, `services`,
  `configmaps`, `secrets`, `serviceaccounts`, `pods`, `pods/exec`, `pods/log`,
  `persistentvolumeclaims`, plus `roles`/`rolebindings`; cluster-scoped it needs `namespaces`
  create/get and the `clusterroles`/`clusterrolebindings` the charts create. `pods/exec` is
  required — that is how `tctl` is invoked.
- Note the escalation caveat: creating ClusterRoleBindings requires the CI SA to already hold
  those permissions, or `escalate`/`bind` on them.

### 8.3 GitHub
- Repo variables and secrets from §5.
- Environment `teleport-ci` with branch protection and (recommended) required reviewers on
  destroy.
- The self-hosted runner registered and online.

## 9. Cross-cutting requirements

### 9.1 Secret hygiene
- The Enterprise license and the kubeconfig are written to files under `$RUNNER_TEMP` with
  mode `0600` and removed in an `always()` cleanup step. **On a persistent self-hosted runner,
  `$RUNNER_TEMP` is not automatically wiped** — the cleanup step is not optional.
- Never `echo`/`cat` either secret; never pass them as CLI arguments (visible in `ps`).
- `kubectl create secret … --dry-run=client -o yaml | kubectl apply -f -` is the only way the
  license reaches the cluster; `-o yaml` output must not be logged.
- Add `::add-mask::` for any value derived from a secret that might appear in output.

### 9.2 Idempotency
Every workflow must be safe to re-run at any point: `helm upgrade --install`,
`tctl create -f` (upsert), `terraform apply`, Route53 `UPSERT`, `kubectl apply`. A failed
deploy is fixed by re-running it, never by manual cleanup.

### 9.3 Let's Encrypt rate limits
LE allows 5 duplicate certificates per registered domain per 168 hours. A persistent
environment plus a PVC that survives `helm upgrade` means normal operation issues one cert and
then reuses it — but a destroy/deploy cycle deletes the PVC and re-issues. **Set
`ACME_USE_STAGING=true` while iterating on the workflows**, and only flip to production once
the pipeline is green. `wait-for-acme.sh` must accept the staging issuer when
`ACME_USE_STAGING=true` (its cert is *not* publicly trusted, so it must skip verification in
that mode and log loudly that it is doing so).

### 9.4 Version coherence
One variable, `TELEPORT_VERSION`, drives the cluster chart, the agent chart, and the EC2
package. Agents must never be newer than the auth service. `verify.yml` asserts the running
versions match.

### 9.5 Observability on failure
Every job's `if: failure()` step must dump the evidence needed to diagnose without cluster
access: `kubectl get all,pvc,events -n <ns>`, `kubectl logs --tail=200` for the auth and proxy
pods and the agent pod, `kubectl describe` on non-Ready pods, `helm status`, `terraform show`,
and for the EC2 agent the cloud-init and Teleport logs retrieved via
`aws ssm send-command` (which is why the agent instance is SSM-enabled). Upload as artifacts.

### 9.6 Cost
Because the environment is persistent, `docs/runbook.md` states the standing cost (runner
instance + agent instance + load balancer + EBS) and reminds the operator that `destroy.yml`
with `keep_cluster=true` drops the agent while keeping the cluster.

## 10. Security requirements

### 10.1 Self-hosted runner and untrusted code — non-negotiable
A self-hosted runner with an IAM instance profile and access to a kubeconfig **must never
execute code from a pull request**. Therefore:

- No workflow that targets the self-hosted runner or the `teleport-ci` environment may use
  `pull_request`, and absolutely not `pull_request_target`.
- `lint.yml` is the only PR-triggered workflow and it runs on `ubuntu-latest` with no secrets.
- `deploy.yml` triggers are `workflow_dispatch` + `push: [main]` only.
- Branch protection on `main` (required review) is the actual control that makes
  `push: [main]` safe. State this in `docs/bootstrap.md` as a hard prerequisite.
- `lint.yml` includes a check that enforces the trigger rule mechanically.

### 10.2 Other
- `permissions: contents: read` at workflow level; raise per-job only if ever needed.
- Pin all third-party actions to a commit SHA. Prefer plain `run:` steps over marketplace
  actions for anything touching secrets.
- The EC2 agent has **no inbound security group rules and no SSH key pair** — reachable only
  through Teleport, which is the feature being demonstrated.
- The runner's IAM role must not include `iam:AttachRolePolicy` / `iam:PutRolePolicy` (§7.2).

## 11. Acceptance criteria

The implementation is done when:

1. `deploy.yml` completes green from a clean state and `https://$TELEPORT_CLUSTER_NAME` serves
   the Teleport web UI with a publicly trusted certificate.
2. `tctl get kube_servers` lists `KUBE_CLUSTER_NAME`; `tctl nodes ls` lists the EC2 instance.
3. Re-running `deploy.yml` with no changes completes green and is a no-op (empty Terraform
   plan, Helm release revision may increment but no pod churn).
4. `destroy.yml` removes the agents, the Helm releases, the PVC, and the DNS record, and can
   be re-run without error.
5. A follow-up `deploy.yml` after a destroy succeeds again — proving no leftover state.
6. `lint.yml` passes on a PR and has no access to secrets.
7. No secret value appears in any workflow log.
8. `docs/bootstrap.md` is complete enough that a new operator can go from an empty AWS account
   + empty repo to a green deploy without further guidance.

## 12. Out of scope

- Creating or managing the Kubernetes cluster itself.
- Teleport HA (multi-replica auth, DynamoDB/etcd backend, `chartMode: aws`).
- SSO connectors, RBAC roles, user provisioning, Machine ID / `tbot`.
- Session recording storage, audit log export.
- Teleport upgrades/migrations beyond bumping `TELEPORT_VERSION`.
- Enrolling apps or databases (the kube agent runs `roles: kube` only).

## 13. Open items (assumptions made; none block implementation)

| Item | Assumption taken | Change by |
|---|---|---|
| Kubernetes distribution | Any conformant cluster with an L4 `LoadBalancer` and a default `StorageClass` | Nothing to change if true; if the LB is L7, switch from `acme` to `tls.existingSecretName` + cert-manager |
| Runner registration credential | GitHub App preferred, PAT acceptable | `terraform/runner-bootstrap` variable |
| Whether the operator wants the runner in the same VPC as the agent | Yes, same VPC, different subnets is fine | `terraform/runner-bootstrap` variables |
| `tsh`-based verification | Not used; `tctl`-via-`kubectl exec` avoids needing a Teleport user | Add a Machine ID join if a true client-side check is later wanted |

---

## Appendix A — `helm/teleport-cluster.values.yaml`

```yaml
chartMode: standalone
clusterName: "${TELEPORT_CLUSTER_NAME}"

enterprise: true
licenseSecretName: license

acme: true
acmeEmail: "${ACME_EMAIL}"
# acmeURI is injected only when ACME_USE_STAGING=true:
#   https://acme-staging-v02.api.letsencrypt.org/directory

proxyListenerMode: multiplex

authentication:
  type: local
  localAuth: true
  secondFactors: ["otp", "webauthn"]

persistence:
  enabled: true
  volumeSize: 10Gi

service:
  type: LoadBalancer

highAvailability:
  replicaCount: 1        # required: ACME is single-pod only

log:
  level: INFO
  format: json           # easier to grep in failure dumps
```

## Appendix B — verified upstream references

- Helm repo: `https://charts.releases.teleport.dev`
- `teleport-cluster` values reference — confirms `chartMode`, `acme`/`acmeEmail`/`acmeURI`,
  `enterprise`, `licenseSecretName` (file must be `license.pem`), ACME single-pod restriction,
  `clusterName` immutability.
- `teleport-kube-agent` values reference — confirms `joinParams` is preferred over `authToken`
  because `authToken` supports only the `token` join method, and that `teleportClusterName` is
  required for the `kubernetes` join method.
- `iam` join token spec (`kind: token`, `join_method: iam`, `allow[].aws_account`,
  `allow[].aws_arn` with `*`/`?` wildcards) and the node-side `teleport.join_params`
  (`token_name`, `method: iam`) + `proxy_server` — matches Appendix in §6.1.
- `kubernetes` in-cluster join token spec (`kubernetes.type: in_cluster`,
  `allow[].service_account: "namespace:name"`) — the chart mounts the SA token by default.
