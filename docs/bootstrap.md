# Bootstrap runbook — from an empty AWS account and an empty repo to a green deploy

This is the one-time setup. Everything here is done **by hand, from your own
machine**, with credentials GitHub never sees. Once it is finished, `deploy.yml`
does the rest and can be re-run forever.

Read it end to end before starting: a couple of decisions (the cluster name, the
load balancer type) cannot be changed later without a full teardown.

Contents:

1. [What you need before you start](#1-what-you-need-before-you-start)
2. [AWS prerequisites](#2-aws-prerequisites)
3. [Kubernetes prerequisites](#3-kubernetes-prerequisites)
4. [Create the GitHub App for runner registration](#4-create-the-github-app-for-runner-registration)
5. [Apply `terraform/runner-bootstrap`](#5-apply-terraformrunner-bootstrap)
6. [Configure the repository](#6-configure-the-repository)
7. [Branch protection — a hard prerequisite](#7-branch-protection--a-hard-prerequisite)
8. [First deploy](#8-first-deploy)
9. [Understanding the runner's IAM role](#9-understanding-the-runners-iam-role)
10. [Optional: SSM on the agent node](#10-optional-ssm-on-the-agent-node)

---

## 1. What you need before you start

| Thing | Why |
|---|---|
| AWS credentials with admin-ish rights, on your machine | To create the runner, its IAM role, the state bucket and the hosted zone. Used once. |
| A public DNS domain you control | ACME must be able to resolve the cluster name from the public internet. |
| A Kubernetes cluster with an **L4** `LoadBalancer` and a default `StorageClass` | See §3. This is the single most common cause of a failed first deploy. |
| A Teleport Enterprise licence file (`license.pem`) | The chart runs the Enterprise image. |
| Terraform >= 1.10, AWS CLI v2, kubectl, helm on your machine | For this bootstrap only. |
| Admin on the GitHub repository | To create the environment, variables, and branch protection. |

Two decisions to make now:

* **`TELEPORT_CLUSTER_NAME`** — e.g. `teleport.ci.example.com`. This becomes the
  cluster name *and* the proxy public address. It is **immutable for the life of
  the cluster**: it is baked into the host CAs and every certificate Teleport
  issues. Changing it later means running `destroy.yml` and starting again.
* **Let's Encrypt staging or production** — leave `ACME_USE_STAGING=true` until the
  pipeline is green (§8). LE allows 5 duplicate certificates per registered domain
  per 168 hours, and each destroy/deploy cycle burns one.

---

## 2. AWS prerequisites

### 2.1 Route53 public hosted zone

```bash
export PARENT_DOMAIN=ci.example.com
aws route53 create-hosted-zone \
  --name "$PARENT_DOMAIN" \
  --caller-reference "teleport-ci-$(date +%s)" \
  --hosted-zone-config Comment="teleport-ci"
```

Note the `Id` (the `ROUTE53_ZONE_ID` repo variable — the bare `Z…` part is fine,
the scripts strip a `/hostedzone/` prefix if present) and the four `NS` records.

**Then actually delegate the zone.** Add those NS records at the registrar (or in
the parent zone) and verify:

```bash
dig +short NS "$PARENT_DOMAIN" @1.1.1.1
```

If this returns nothing, ACME will fail 15 minutes into your first deploy and the
cause will not be obvious. `deploy.yml`'s preflight job checks that
`TELEPORT_CLUSTER_NAME` is inside the zone and that the zone is public, but it
cannot check that the world's resolvers agree.

### 2.2 Terraform state bucket

Versioning is **required** — preflight asserts it, because state corruption is
otherwise unrecoverable.

```bash
export TF_STATE_BUCKET=example-teleport-ci-tfstate
export AWS_REGION=eu-west-1

aws s3api create-bucket --bucket "$TF_STATE_BUCKET" \
  --region "$AWS_REGION" \
  --create-bucket-configuration LocationConstraint="$AWS_REGION"

aws s3api put-bucket-versioning --bucket "$TF_STATE_BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-public-access-block --bucket "$TF_STATE_BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws s3api put-bucket-encryption --bucket "$TF_STATE_BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
```

No DynamoDB lock table is needed: the backend uses S3 native conditional-write
locking (`use_lockfile = true`, Terraform >= 1.10).

### 2.3 Networking

You need a VPC with:

* a subnet with **outbound** internet access (NAT gateway, or a public subnet) for
  the runner, and
* a subnet with outbound internet access for the agent node.

Same VPC, different subnets is fine. Neither instance gets any inbound rules.

---

## 3. Kubernetes prerequisites

### 3.1 The load balancer must be L4 / TCP passthrough

Teleport's ACME implementation uses the **TLS-ALPN-01** challenge on port 443. The
challenge is answered inside the TLS handshake, so **any load balancer that
terminates TLS will make ACME fail.** In practice:

| Load balancer | Works? |
|---|---|
| AWS NLB (`service.beta.kubernetes.io/aws-load-balancer-type: nlb`) | yes |
| AWS classic ELB in TCP mode | yes |
| MetalLB / kube-vip (reports `.ip`) | yes |
| GCP / Azure L4 load balancer | yes |
| AWS ALB, or any Ingress controller that terminates TLS | **no** |

If your only option is an L7 load balancer, this design does not apply: switch
`helm/teleport-cluster.values.yaml` from `acme: true` to
`tls.existingSecretName` plus cert-manager, and drop `wait-for-acme.sh`. That is
out of scope for this repository.

On EKS, install the AWS Load Balancer Controller and annotate the Service, or use
the in-tree NLB annotation via `service.spec` in the values file.

### 3.2 StorageClass

You need a default `StorageClass` that can provision a 10 GiB `ReadWriteOnce`
volume. `kubectl get storageclass` should show one marked `(default)`.

### 3.3 The CI ServiceAccount

The `KUBECONFIG` secret must be a kubeconfig for a **ServiceAccount**, not a
cluster-admin user certificate.

```bash
export NS_CLUSTER=teleport
export NS_AGENT=teleport-agent

kubectl create namespace "$NS_CLUSTER" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "$NS_AGENT"   --dry-run=client -o yaml | kubectl apply -f -
kubectl -n kube-system create serviceaccount teleport-ci

cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: teleport-ci
  namespace: ${NS_CLUSTER}
rules:
  - apiGroups: [""]
    resources: [services, configmaps, secrets, serviceaccounts, pods,
                pods/exec, pods/log, persistentvolumeclaims, events]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [apps]
    resources: [deployments, statefulsets, replicasets]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [batch]
    resources: [jobs]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [rbac.authorization.k8s.io]
    resources: [roles, rolebindings]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [policy]
    resources: [poddisruptionbudgets]
    verbs: [get, list, watch, create, update, patch, delete]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: teleport-ci
  namespace: ${NS_AGENT}
rules:
  - apiGroups: [""]
    resources: [services, configmaps, secrets, serviceaccounts, pods,
                pods/exec, pods/log, persistentvolumeclaims, events]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [apps]
    resources: [deployments, statefulsets, replicasets]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [batch]
    resources: [jobs]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [rbac.authorization.k8s.io]
    resources: [roles, rolebindings]
    verbs: [get, list, watch, create, update, patch, delete]
  - apiGroups: [policy]
    resources: [poddisruptionbudgets]
    verbs: [get, list, watch, create, update, patch, delete]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: teleport-ci
  namespace: ${NS_CLUSTER}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: teleport-ci}
subjects: [{kind: ServiceAccount, name: teleport-ci, namespace: kube-system}]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: teleport-ci
  namespace: ${NS_AGENT}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: teleport-ci}
subjects: [{kind: ServiceAccount, name: teleport-ci, namespace: kube-system}]
EOF
```

Cluster-scoped permissions. **Read the escalation note below before applying.**

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: teleport-ci
rules:
  - apiGroups: [""]
    resources: [namespaces]
    verbs: [get, list, create]
  - apiGroups: [""]
    resources: [nodes, persistentvolumes]
    verbs: [get, list]
  - apiGroups: [rbac.authorization.k8s.io]
    resources: [clusterroles, clusterrolebindings]
    verbs: [get, list, watch, create, update, patch, delete, bind, escalate]
  - apiGroups: [apiextensions.k8s.io]
    resources: [customresourcedefinitions]
    verbs: [get, list]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: teleport-ci
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: teleport-ci}
subjects: [{kind: ServiceAccount, name: teleport-ci, namespace: kube-system}]
EOF
```

> **Escalation caveat.** Kubernetes will not let a subject create a
> ClusterRole/ClusterRoleBinding granting permissions the subject does not already
> hold, unless it has `escalate` / `bind` on them. The `teleport-cluster` chart
> creates a ClusterRole (for `TokenReview`/`SubjectAccessReview` delegation), so
> the CI ServiceAccount needs `escalate` and `bind` as above. `escalate` is
> effectively cluster-admin-by-construction: **treat the `KUBECONFIG` secret as a
> cluster-admin credential** and protect the `teleport-ci` environment
> accordingly. If that is unacceptable, pre-create the charts' ClusterRole and
> ClusterRoleBinding yourself and set `rbac.create=false` in the values files —
> then you can drop `escalate`/`bind`.

Now build the kubeconfig from a bound ServiceAccount token:

```bash
SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
CA="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
# 1 year; re-issue before it expires (see docs/runbook.md).
TOKEN="$(kubectl -n kube-system create token teleport-ci --duration=8760h)"

cat >/tmp/ci-kubeconfig <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: ci
    cluster:
      server: ${SERVER}
      certificate-authority-data: ${CA}
users:
  - name: teleport-ci
    user:
      token: ${TOKEN}
contexts:
  - name: ci
    context: {cluster: ci, user: teleport-ci}
current-context: ci
EOF

# Verify it works before handing it to CI.
KUBECONFIG=/tmp/ci-kubeconfig kubectl auth can-i create pods/exec -n "$NS_CLUSTER"

# This is the value of the KUBECONFIG repository secret.
base64 -w0 </tmp/ci-kubeconfig
shred -u /tmp/ci-kubeconfig
```

Some clusters cap `--duration`; if so, use the longest allowed value and put the
renewal in your calendar, or create a long-lived `kubernetes.io/service-account-token`
Secret instead.

---

## 4. Create the GitHub App for runner registration

The runner mints a short-lived registration token at every boot rather than
holding a long-lived credential. A GitHub App is the recommended source; a classic
PAT works but is weaker (long-lived, tied to a human account, and broader than
this one job needs).

1. **Settings → Developer settings → GitHub Apps → New GitHub App.**
   * Homepage URL: anything.
   * Uncheck **Webhook → Active**.
   * Repository permissions: **Administration: Read and write** (this is what
     `POST /repos/{owner}/{repo}/actions/runners/registration-token` requires).
     Nothing else.
   * Where can this app be installed: *Only on this account*.
2. Note the **App ID**.
3. **Generate a private key** and download the `.pem`.
4. **Install App** on the single repository. The install URL ends in
   `/installations/<installation id>` — note the **Installation ID**. If you miss
   it: `GET /repos/{owner}/{repo}/installation` with an App JWT returns it.
5. Put the private key in SSM Parameter Store as a `SecureString`:

```bash
aws ssm put-parameter \
  --name /teleport-ci/github-app-private-key \
  --type SecureString \
  --value "file:///path/to/app-private-key.pem" \
  --region "$AWS_REGION"
```

Terraform deliberately does **not** manage this parameter, so the private key
never enters Terraform state.

<details>
<summary>PAT alternative (weaker)</summary>

Create a classic PAT with the `repo` scope, store it the same way, and set
`runner_credential_source = "pat"`. A PAT is long-lived, cannot be scoped to
"register runners" only, and dies with the account that owns it. Prefer the App.
</details>

---

## 5. Apply `terraform/runner-bootstrap`

This is applied **once, by hand**. The runner's own IAM role cannot re-create it:
that role can only create IAM roles under `/teleport-ci/`.

```bash
cd terraform/runner-bootstrap

cat >terraform.tfvars <<EOF
aws_region      = "eu-west-1"
vpc_id          = "vpc-0123456789abcdef0"
subnet_id       = "subnet-0123456789abcdef0"   # outbound internet required
assign_public_ip = false                       # true only for a public subnet with no NAT

tf_state_bucket = "example-teleport-ci-tfstate"
route53_zone_id = "Z0123456789ABCDEFGHIJ"

github_owner = "example-org"
github_repo  = "teleport-ci"
runner_label = "teleport-ci"

runner_credential_source   = "github_app"
github_app_id              = "123456"
github_app_installation_id = "78901234"
credential_ssm_parameter   = "/teleport-ci/github-app-private-key"

teleport_version = "18.11.1"
EOF

terraform init
terraform apply
terraform output next_steps
```

What it creates:

* An Amazon Linux 2023 `t3.small` with a 30 GiB gp3 root volume, IMDSv2 required,
  detailed monitoring off, `Name = github-runner-teleport-ci`.
* A security group with **no inbound rules** and no key pair. Administrative
  access is via SSM Session Manager only.
* The runner IAM role and its five inline policies plus a guardrail Deny (§9).
* User-data that installs the versions pinned in `tool-versions.env`
  (kubectl, helm, terraform, AWS CLI v2, jq, gettext/envsubst, git, curl, plus
  `tsh`/`tctl` for manual debugging) and registers a single non-ephemeral runner
  as a systemd service (`github-runner.service`) running as the non-root `runner`
  user with labels `self-hosted,linux,x64,<runner_label>`.

The state file for this module is **local** and is not in the CI state bucket.
Keep it somewhere durable and private, or add your own backend block.

Confirm the runner came up:

```bash
terraform output -raw ssm_session_command   # then run it
sudo journalctl -u github-runner -n 100 --no-pager
sudo tail -n 100 /var/log/cloud-init-output.log   # look for RUNNER_BOOTSTRAP_OK
```

and that it shows as **Idle** under
*Settings → Actions → Runners* with the four expected labels.

---

## 6. Configure the repository

### 6.1 Environment `teleport-ci`

*Settings → Environments → New environment → `teleport-ci`.*

* **Deployment branches:** *Selected branches* → `main` only.
* **Required reviewers:** at least one, for `destroy.yml`. Recommended for
  `deploy.yml` too. (Both use this environment, so a reviewer requirement applies
  to both — decide whether that friction is worth it for deploys.)
* **Environment secrets:**

| Secret | Value |
|---|---|
| `KUBECONFIG` | the `base64 -w0` output from §3.3 |
| `TELEPORT_ENTERPRISE_LICENSE` | the full contents of `license.pem`, including the BEGIN/END lines |

That is the entire secret surface. **No AWS credentials, no join tokens** — the
runner uses its instance profile, and both agents use delegated join methods that
have no shared secret at all.

### 6.2 Repository variables

*Settings → Actions → Variables → Repository variables.*

| Name | Example | Notes |
|---|---|---|
| `TELEPORT_VERSION` | `18.11.1` | Chart version for both releases and the EC2 package version. Single source of truth. |
| `TELEPORT_CLUSTER_NAME` | `teleport.ci.example.com` | **Immutable.** Must be inside `ROUTE53_ZONE_ID`. |
| `ACME_EMAIL` | `infra@example.com` | LE registration contact. |
| `ACME_USE_STAGING` | `true` | Start with `true`. See §8. |
| `AWS_REGION` | `eu-west-1` | Must match `aws_region` in runner-bootstrap. |
| `ROUTE53_ZONE_ID` | `Z0123456789ABCDEFGHIJ` | |
| `TF_STATE_BUCKET` | `example-teleport-ci-tfstate` | |
| `EC2_AGENT_INSTANCE_TYPE` | `t3.micro` | |
| `EC2_AGENT_SUBNET_ID` | `subnet-…` | Outbound internet required. |
| `EC2_AGENT_VPC_ID` | `vpc-…` | |
| `K8S_NAMESPACE_CLUSTER` | `teleport` | |
| `K8S_NAMESPACE_AGENT` | `teleport-agent` | |
| `KUBE_CLUSTER_NAME` | `ci-k8s` | Display name in Teleport. |
| `RUNNER_LABEL` | `teleport-ci` | Must match `runner_label` in runner-bootstrap. |

---

## 7. Branch protection — a hard prerequisite

`deploy.yml` is triggered by `push` to `main` and runs on the self-hosted runner
with the IAM instance profile and the kubeconfig. **Branch protection with a
required review on `main` is the control that makes that safe.** Without it,
anyone who can push to `main` can run arbitrary code on the runner.

*Settings → Branches → Add branch protection rule* for `main`:

* Require a pull request before merging, with at least 1 approval.
* Require status checks to pass: the `lint` workflow's jobs.
* Do not allow bypassing the above settings.
* Restrict who can push.

The complementary half of this is that **no workflow targeting the self-hosted
runner or the `teleport-ci` environment may be triggered by `pull_request` or
`pull_request_target`.** `lint.yml` is the only PR-triggered workflow, runs on
`ubuntu-latest`, and gets no secrets. Its `trigger-rules` job enforces this for
every workflow in the repository, including itself, so the rule cannot be
regressed silently.

---

## 8. First deploy

1. Leave `ACME_USE_STAGING=true`.
2. *Actions → deploy → Run workflow* on `main`.
3. Expect it to reach `wait-for-acme.sh` and issue from the LE **staging** CA. The
   staging chain is not publicly trusted, so:
   * `wait-for-acme.sh` logs loudly that it is skipping verification;
   * the `verify` job reports the public-trust assertion as **skipped**;
   * the **`kube-agent` job will fail**, because `insecureSkipProxyTLSVerify` is
     `false` by design and the agent cannot verify a staging certificate.

   That is expected. The point of the staging pass is to prove the DNS, load
   balancer, Helm, licence and token plumbing without burning production
   certificates. Run with `skip_kube_agent: true` if you want a fully green
   staging run.
4. When the staging run gets that far, set `ACME_USE_STAGING=false` and re-run
   `deploy.yml`. Because the PVC persists, the cluster keeps its identity; only
   the certificate is re-issued.
5. Success looks like:
   * `https://$TELEPORT_CLUSTER_NAME` serves the Teleport web UI with a publicly
     trusted certificate;
   * the `verify` job's step summary shows the kube cluster name and the EC2
     instance ID;
   * re-running `deploy.yml` with no changes is a no-op (empty Terraform plan).

Create your first Teleport user from the runner:

```bash
# on the runner, over SSM, with the repo checked out
K8S_NAMESPACE_CLUSTER=teleport ./scripts/tctl.sh users add admin --roles=editor,access,auditor
```

If something goes wrong, see [`runbook.md`](runbook.md) — the failure-mode table
there is ordered by how often each cause actually bites.

---

## 9. Understanding the runner's IAM role

**This is the sharpest edge in the design, so it is spelled out.**

Anyone who can run a workflow on this runner can create an IAM role and attach it
to an EC2 instance. Three things keep that from being privilege escalation:

1. **Path scoping.** `iam:CreateRole`, `iam:DeleteRole`, the instance-profile
   actions and friends are granted only on
   `arn:aws:iam::*:role/teleport-ci/*` and
   `arn:aws:iam::*:instance-profile/teleport-ci/*`. Existing roles elsewhere in the
   account cannot be read, modified or deleted.
2. **`iam:PassRole` is conditioned.** It is allowed only for
   `arn:aws:iam::*:role/teleport-ci/*` and only with
   `Condition: StringEquals: {"iam:PassedToService": "ec2.amazonaws.com"}`. The
   runner cannot hand a role to Lambda, CodeBuild, or anything else.
3. **The role cannot grant permissions to anything.** The runner has **no**
   `iam:AttachRolePolicy` and **no** `iam:PutRolePolicy`. This is what makes a role
   it creates useless: it can only ever be an empty, no-op role. `main.tf` goes
   further and attaches an explicit `Deny` on `AttachRolePolicy`, `PutRolePolicy`,
   `CreatePolicy`, `CreateUser`, `CreateAccessKey`, `UpdateAssumeRolePolicy` and
   friends — so the property survives someone later attaching a broader managed
   policy to the runner role.

The rest of the role is scoped as follows:

| Purpose | Scope |
|---|---|
| `sts:GetCallerIdentity` | `*` (has no resource form) |
| Terraform state | the state bucket and the `teleport-ci/` prefix only, plus read-only `GetBucketVersioning`/`GetBucketLocation` for preflight |
| Route53 changes | `hostedzone/<ROUTE53_ZONE_ID>` only |
| `route53:GetChange` | `*` (not resource-scopable; required by `aws route53 wait`) |
| AMI lookup | `parameter/aws/service/ami-amazon-linux-latest/*` only |
| Runner registration credential | the one SSM parameter, plus `kms:Decrypt` conditioned on `kms:ViaService = ssm.<region>.amazonaws.com` |
| `ec2:Describe*` | `*`, conditioned on `aws:RequestedRegion` |
| `ec2:RunInstances`, `CreateSecurityGroup` | region-conditioned |
| `ec2:CreateTags` on create | region-conditioned **and** `ec2:CreateAction` in `RunInstances`/`CreateSecurityGroup`/`CreateVolume`. Without this the runner could tag somebody else's instance `ManagedBy=github-actions` and then terminate it using the row below. |
| `TerminateInstances`, `DeleteSecurityGroup`, egress rule changes, `ModifyInstance*`, `GetConsoleOutput` | region-conditioned **and** `aws:ResourceTag/ManagedBy = github-actions` |
| SSM Session Manager | `AmazonSSMManagedInstanceCore` managed policy |

The runner role has **no Kubernetes permissions at all** — the kubeconfig is a
GitHub secret, and nothing in the Kubernetes path depends on AWS. That is also why
the in-cluster agent uses the `kubernetes` join method rather than `iam`.

---

## 10. Optional: SSM on the agent node

By design the EC2 agent's IAM role is a **no-op role**: it exists only so the
instance presents an assumed-role ARN that the provision token can match. That
means `aws ssm send-command` cannot reach it, so `deploy.yml`'s failure dump uses
`ec2:GetConsoleOutput` instead — cloud-init writes user-data output to the serial
console, which is enough to see whether user-data succeeded (look for
`TELEPORT_BOOTSTRAP_OK` / `TELEPORT_BOOTSTRAP_FAILED`).

If you want a real interactive shell on the agent for debugging, you have two
options, both of which trade away the no-op property:

* **Recommended: attach it yourself, out of band.**

  ```bash
  aws iam attach-role-policy \
    --role-name teleport-ci-ec2-agent \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  ```

  Note that `terraform destroy` will then **fail** to delete the role
  (`DeleteConflict`), because the runner has no `iam:DetachRolePolicy`. Detach it
  by hand before a teardown.

* **`attach_ssm_policy = true`** in `terraform/ec2-agent`. This will fail with
  `AccessDenied` when applied from the runner, because of the guardrail `Deny` in
  §9. Making it work means relaxing that Deny, which is exactly the property you
  do not want to give up. Use it only if you apply that module by hand.

Neither is needed for normal operation: once the agent has joined, `tsh ssh` into
it — which is the whole point of the exercise.
