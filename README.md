# teleport-ci — a Teleport cluster and two agents, deployed by GitHub Actions

This repository deploys and manages, entirely from GitHub Actions:

1. **A Teleport Enterprise cluster** on a pre-existing Kubernetes cluster, using
   the official [`teleport-cluster`](https://charts.releases.teleport.dev) Helm
   chart, on a real public hostname (Route53) with a Let's Encrypt certificate
   (ACME / TLS-ALPN-01).
2. **A Teleport Agent on Kubernetes** (`teleport-kube-agent`), joining with the
   `kubernetes` in-cluster method — enrols the cluster for `tsh kube` access.
3. **A Teleport Agent on an EC2 node**, provisioned by Terraform, joining with the
   `iam` method — enrols the node for `tsh ssh` access.

The environment is **persistent**: `deploy.yml` brings it up and leaves it running;
`destroy.yml` tears it down.

The full design and its rationale is in [`SPEC.md`](SPEC.md).
**New operator? Start with [`docs/bootstrap.md`](docs/bootstrap.md).**
Day-2 operations and the failure-mode table are in
[`docs/runbook.md`](docs/runbook.md).

---

## Architecture

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
   ┌──────────────────────┐   ┌───────────────────────────┐
   │ Kubernetes cluster   │   │ AWS                       │
   │                      │   │                           │
   │ ns: teleport         │   │  Route53 hosted zone      │
   │  teleport-cluster    │◀──┼─ A/CNAME → Service LB     │
   │  (Enterprise, ACME)  │   │                           │
   │  Service LoadBalancer│   │  EC2 agent instance       │
   │                      │   │   + no-op instance profile│
   │ ns: teleport-agent   │   │   joins via `iam` ────────┼──┐
   │  teleport-kube-agent │   │                           │  │
   │  joins via           │   │  S3 + native lock (state) │  │
   │  `kubernetes` method │   └───────────────────────────┘  │
   │        │             │                                  │
   │        └─────────────┴──── joins ───▶ Proxy :443 ◀──────┘
   └──────────────────────┘
```

### Join methods, and why

| Agent | Method | Why |
|---|---|---|
| Kubernetes agent | `kubernetes`, `type: in_cluster` | The agent runs in the same cluster as the Auth Service, which validates its ServiceAccount JWT directly. **No shared secret exists at all**, so the token name is not sensitive. |
| EC2 agent | `iam` | The node proves its identity with a signed `sts:GetCallerIdentity` request, restricted by `aws_account` + `aws_arn`. **No shared secret**, so the token name is not sensitive. |

Static/secret join tokens are deliberately **not** used. That removes the whole
class of "token leaked into a workflow log" failures and is why
`teleport/tokens/*.yaml` can live in git in plaintext.

---

## The whole secret surface

Two environment secrets on the `teleport-ci` GitHub Environment:

| Secret | Contents |
|---|---|
| `KUBECONFIG` | base64 of a kubeconfig for the CI ServiceAccount (not cluster-admin) |
| `TELEPORT_ENTERPRISE_LICENSE` | the contents of `license.pem` |

**No AWS credentials** (the runner uses an IAM instance profile) and **no join
tokens** (both join methods are delegated). Repository *variables* carry the rest of
the configuration — see [`docs/bootstrap.md`](docs/bootstrap.md) §6.2.

---

## Workflows

| Workflow | Trigger | Runner |
|---|---|---|
| `deploy.yml` | `workflow_dispatch`, `push` to `main` | self-hosted, `teleport-ci` environment |
| `destroy.yml` | `workflow_dispatch` only, with typed confirmation | self-hosted, `teleport-ci` environment |
| `verify.yml` | `workflow_call` (reusable) | self-hosted, `teleport-ci` environment |
| `lint.yml` | `pull_request`, `push` to `main` | `ubuntu-latest`, **no secrets** |

```
preflight ──▶ cluster ──▶ tokens ──┬─▶ kube-agent ──┐
                                   └─▶ ec2-agent ───┴─▶ verify
```

### Security posture

A self-hosted runner with an IAM instance profile and a kubeconfig **must never
execute code from a pull request.** Therefore:

* No workflow that targets the self-hosted runner or the `teleport-ci` environment
  uses `pull_request`, and absolutely not `pull_request_target`.
* `lint.yml` is the only PR-triggered workflow, runs on `ubuntu-latest`, and is
  given no secrets and no environment.
* `lint.yml`'s `trigger-rules` job **enforces this mechanically** for every
  workflow in the repository, including itself. It parses each workflow, decides
  whether it is privileged (self-hosted runner, an `environment:`, forwarded
  secrets, or a call into a privileged reusable workflow), and fails if a
  privileged workflow is reachable from a pull request.
* **Branch protection with a required review on `main` is the control that makes
  the `push: [main]` trigger safe.** It is a hard prerequisite, not a nice-to-have.
* All third-party actions are pinned to commit SHAs; anything touching a secret is a
  plain `run:` step.
* `permissions: contents: read` at workflow level.
* The runner's IAM role is path-scoped to `/teleport-ci/` for `iam:*`, has
  `iam:PassRole` conditioned on `iam:PassedToService: ec2.amazonaws.com`, and has
  **no** `iam:AttachRolePolicy` / `iam:PutRolePolicy` (plus an explicit `Deny`).
  See [`docs/bootstrap.md`](docs/bootstrap.md) §9.

### Secret hygiene

The licence and the kubeconfig are written to files under `$RUNNER_TEMP` with mode
`0600`, never echoed, never passed as command-line arguments, and removed in an
`always()` cleanup step in every job. **On a persistent self-hosted runner
`$RUNNER_TEMP` is not automatically wiped**, so those cleanup steps are not
optional.

### Idempotency

Every workflow is safe to re-run at any point: `helm upgrade --install`,
`tctl create -f` (upsert), Route53 `UPSERT`, `terraform apply`, `kubectl apply`. A
failed deploy is fixed by re-running it, never by manual cleanup.

---

## Repository layout

```
.
├── .github/
│   ├── workflows/
│   │   ├── deploy.yml      # main entrypoint
│   │   ├── destroy.yml     # manual teardown, typed confirmation
│   │   ├── verify.yml      # reusable: asserts cluster + both agents are healthy
│   │   └── lint.yml        # PR gate; GitHub-hosted, no secrets
│   └── actions/setup-tools/action.yml   # verifies (never installs) runner tooling
├── helm/
│   ├── teleport-cluster.values.yaml     # envsubst-templated
│   └── teleport-kube-agent.values.yaml  # envsubst-templated
├── teleport/tokens/
│   ├── kube-agent-token.yaml            # kubernetes / in_cluster
│   └── ec2-agent-token.yaml             # iam
├── terraform/
│   ├── ec2-agent/          # applied by deploy.yml
│   └── runner-bootstrap/   # applied ONCE, by hand (docs/bootstrap.md)
├── scripts/
│   ├── kubeconfig.sh       # materialise KUBECONFIG to a 0600 temp file
│   ├── route53-upsert.sh   # point DNS at the Service load balancer
│   ├── route53-delete.sh
│   ├── tctl.sh             # run tctl inside the auth pod via kubectl exec
│   ├── wait-for-acme.sh    # poll until the proxy serves a valid certificate
│   └── verify.sh           # the assertions used by verify.yml
├── docs/
│   ├── bootstrap.md        # one-time setup, end to end
│   └── runbook.md          # deploy, destroy, debug, cost
├── tool-versions.env       # single source of truth for runner tooling versions
├── SPEC.md
└── README.md
```

---

## Things that will bite you

Two, ordered by likelihood. Both are covered in detail in
[`docs/runbook.md`](docs/runbook.md) §3.

1. **The `Service type: LoadBalancer` must be L4 / TCP passthrough.** Teleport's
   ACME uses the TLS-ALPN-01 challenge on port 443, answered inside the TLS
   handshake. An L7 load balancer that terminates TLS makes ACME fail, and this is
   the single most likely cause of a failed first deploy.
2. **Let's Encrypt rate limits.** Five duplicate certificates per registered domain
   per 168 hours. Normal operation issues one and reuses it, but each
   destroy/deploy cycle deletes the PVC and re-issues. Keep
   `ACME_USE_STAGING=true` while iterating on the pipeline.

And one to know about before your first `destroy`: `destroy.yml` **deletes the
PVC**. That is deliberate — `helm uninstall` leaves it behind, and a surviving PVC
means the next deploy silently reuses the old cluster state and CA.

---

## Out of scope

Creating or managing the Kubernetes cluster; Teleport HA (multi-replica auth,
DynamoDB/etcd backends, `chartMode: aws`); SSO connectors, RBAC roles, user
provisioning, Machine ID / `tbot`; session recording storage and audit log export;
enrolling apps or databases (the kube agent runs `roles: kube` only).
