# Spec (MVP): Deploy a Teleport cluster to Kubernetes with GitHub Actions

**Status:** ready for implementation
**Branch:** `mvp-cluster-only`
**Date:** 2026-09-17
**Teleport / chart version:** `18.11.1`
**Audience:** an operator with **no prior GitHub Actions experience**

---

## 1. Goal

Deploy **only** a Teleport Enterprise cluster to an existing Kubernetes cluster, using the
official `teleport-cluster` Helm chart, from a GitHub Actions workflow running on a
self-hosted runner.

No agents. No Terraform. No cloud provider. No GitHub secrets.

The secondary goal is equally important: **the repository must teach the operator how GitHub
Actions works.** Clarity beats cleverness everywhere in this spec. If a choice makes the YAML
shorter but harder to follow, choose the longer, more obvious version.

### 1.1 Explicitly not in scope

Agents of any kind (kube, EC2, app, db), Terraform, cloud APIs, DNS automation, certificate
issuance or renewal, SSO/RBAC configuration, HA, backup/restore, Teleport upgrades beyond
bumping a version variable.

## 2. What changed from the v1 spec, and why it is simpler

| v1 | MVP | Consequence |
|---|---|---|
| ACME / Let's Encrypt | **Pre-provisioned TLS secret** (`tls.existingSecretName`) | Removes the L4-vs-L7 load balancer trap, the LE rate-limit problem, and the DNS-before-cert ordering dance. This is a genuine simplification, not just a shortcut. |
| Workflow created the license secret from a GitHub secret | **Operator pre-creates the license secret**; workflow only asserts it exists | Zero GitHub secrets. The license never enters the pipeline. |
| Route53 API calls from the workflow | **Operator configures DNS by hand** | No cloud credentials at all. Safe because with a pre-provisioned cert, *nothing in the deploy depends on DNS resolving* — only clients do. |
| Two agents, Terraform, IAM roles | **Nothing but the cluster** | Roughly one fifth of the moving parts. |
| 4 workflows + composite action + 6 scripts | **3 workflows, inline steps, 1 runner installer** | Fewer files to jump between while learning. |

## 3. Decisions (confirmed with the operator)

| Question | Decision |
|---|---|
| Runner credentials for Kubernetes? | **Out of scope for the pipeline.** The runner is expected to have working `kubectl` access already — most likely via Teleport Machine & Workload Identity (MWI) from a *separate* Teleport cluster, giving it short-lived credentials. The workflow must make **no assumption** about where that access comes from and must never read, write, or handle a credential. |
| Load balancer available? | **Make it configurable.** Default `LoadBalancer`; support `NodePort` and `ClusterIP`. Detect a stuck `<pending>` Service and report it clearly instead of timing out silently. |
| Edition? | **Enterprise.** License secret pre-provisioned by the operator. "Avoid secrets" refers to the *pipeline's* exposure surface, not to the operator's prerequisites. |
| Scope of deliverables? | Deploy + uninstall workflows, tutorial README, runner install script, **plus** a PR lint/validation workflow. |

### 3.1 Design consequence of the credential decision

Because credentials are ambient and out of scope, the workflow's contract with the runner is
exactly: *"`kubectl` and `helm` are on `PATH` and already authenticated to the right cluster."*

This is what makes the pipeline secret-free, and it means the implementation must:

- Never reference `secrets.*` in the deploy or uninstall workflow. **Zero** GitHub secrets.
- Verify that access works in a preflight step, and fail with a message that tells the
  operator to check their runner's credential setup — not with an obscure Helm error.
- Never assume a `KUBECONFIG` path, a context name, or a credential type.

## 4. Repository layout on this branch

```
.
├── .github/workflows/
│   ├── deploy.yml            # install/upgrade the cluster
│   ├── uninstall.yml         # remove it (manual, typed confirmation)
│   └── lint.yml              # PR checks; GitHub-hosted, no secrets, no self-hosted runner
├── helm/
│   └── values.yaml           # the only chart config; envsubst-templated
├── runner/
│   └── install-runner.sh     # set up a self-hosted runner on any Linux VM
├── docs/
│   ├── github-actions-101.md # the tutorial (§8)
│   ├── setup.md              # one-time prerequisites checklist
│   └── runbook.md            # day-2: deploy, upgrade, rotate cert, uninstall, debug
├── README.md                 # start here; 1 page, links to the above
└── SPEC-MVP.md               # this file
```

### 4.1 Handling of the v1 files (implementer: do this)

The v1 implementation (four workflows, two Terraform modules, six scripts) is fully preserved
on the `master` branch and in git history. On the `mvp-cluster-only` branch, **delete**
`.github/`, `helm/`, `scripts/`, `teleport/`, `terraform/`, `tool-versions.env`, and
`docs/bootstrap.md` before creating the MVP tree — two competing sets of workflows in
`.github/workflows/` would both be live on GitHub and would confuse exactly the audience this
MVP is written for.

Keep `SPEC.md` (the v1 spec) in place as reference, and have `README.md` say in one line that
the full-fat version lives on `master`.

### 4.2 No `scripts/` directory — deliberate

Logic goes in **inline `run:` steps with comments**, not in separate shell scripts. A novice
reading `deploy.yml` should be able to see everything that happens without opening another
file. `actionlint` runs `shellcheck` over inline `run:` blocks, so lint coverage is not lost.
The one exception is `runner/install-runner.sh`, which is not part of any workflow.

## 5. Configuration surface

### 5.1 Repository variables (Settings → Secrets and variables → Actions → *Variables*)

| Variable | Example | Required | Notes |
|---|---|---|---|
| `TELEPORT_VERSION` | `18.11.1` | yes | Chart version and Teleport version — one source of truth. |
| `TELEPORT_CLUSTER_NAME` | `teleport.example.com` | yes | Chart `clusterName`. The DNS name users will type. **Immutable for the life of the cluster.** |
| `K8S_NAMESPACE` | `teleport` | yes | Must already exist and already contain both secrets. |
| `TLS_SECRET_NAME` | `teleport-tls` | yes | Existing `kubernetes.io/tls` secret with `tls.crt` + `tls.key`. |
| `LICENSE_SECRET_NAME` | `teleport-license` | yes | Existing secret with a **`license.pem`** key. |
| `SERVICE_TYPE` | `LoadBalancer` | no (default `LoadBalancer`) | `LoadBalancer` \| `NodePort` \| `ClusterIP`. |
| `PUBLIC_ADDR` | `teleport.example.com:32443` | no | **Required when `SERVICE_TYPE=NodePort`** — see §6.4. |
| `STORAGE_CLASS` | `standard` | no | Omit to use the cluster default. |
| `VOLUME_SIZE` | `10Gi` | no (default `10Gi`) | |
| `RUNNER_LABEL` | `teleport-mvp` | yes | Label identifying your self-hosted runner. |

### 5.2 Repository secrets

**None.** This is a stated goal, and `lint.yml` enforces it mechanically (§7.3).

If a future iteration needs one, that is a deliberate decision to make then — not a default
to drift into.

## 6. `deploy.yml`

### 6.1 Triggers and top-level

```yaml
name: Deploy Teleport cluster

on:
  workflow_dispatch:          # a button in the Actions tab
    inputs:
      dry_run:
        description: 'Render and validate only — do not install'
        type: boolean
        default: false

concurrency:
  group: teleport-mvp
  cancel-in-progress: false   # never interrupt a half-finished Helm install

permissions:
  contents: read              # this workflow only needs to read its own repo
```

**`workflow_dispatch` only, for the MVP.** A novice operator should push the button
deliberately and watch what happens, rather than have a `git push` mutate a live cluster. The
tutorial explains how to add a `push:` trigger later, and why branch protection matters if
they do (§7.1).

The `dry_run` input is a teaching device as much as a feature: it demonstrates workflow inputs
and gives a completely safe way to explore the pipeline.

### 6.2 Single job, sequential steps

**One job, not a job graph.** Multiple jobs would mean explaining `needs:`, job outputs, and
the fact that each job gets a fresh working directory — real concepts, but not on page one.
One job with clearly named steps reads top to bottom like a script.

```yaml
jobs:
  deploy:
    runs-on: [self-hosted, linux, "${{ vars.RUNNER_LABEL }}"]
    timeout-minutes: 20
    steps: …
```

### 6.3 Steps

Each step gets a `name:` written as a plain-English sentence, and a comment above it saying
*why* it exists.

**1. Check out the repository** — `actions/checkout` pinned to a commit SHA. Comment must
explain what checkout does (the runner starts with an empty directory) and why third-party
actions are pinned to SHAs rather than tags.

**2. Show the configuration** — echo every `vars.*` value into the log and into
`$GITHUB_STEP_SUMMARY`. Cheap, and it makes the "variables come from repo settings" idea
concrete. Nothing here is sensitive.

**3. Check the tools are present** — `kubectl version --client`, `helm version`, `jq`,
`openssl`, `envsubst`. On failure, point at `runner/install-runner.sh`.

**4. Check we can reach the cluster** — `kubectl cluster-info`, then
`kubectl auth can-i --list -n "$K8S_NAMESPACE"` limited to what we need. On failure the message
must say: *"the runner's Kubernetes credentials are not working — this workflow does not manage
them, see docs/setup.md"*. This is the single most likely first-run failure and it must not
surface as a Helm timeout.

**5. Check the namespace exists** — do **not** create it. The namespace holds
operator-provisioned secrets; if it is missing, something is wrong with the operator's setup
and silently creating an empty one would produce a confusing failure two steps later.

**6. Check the TLS secret** — assert it exists, has `type: kubernetes.io/tls`, and has both
`tls.crt` and `tls.key` keys. Then decode **only `tls.crt`** (public data) and with `openssl`:
- assert `TELEPORT_CLUSTER_NAME` matches the CN or a SAN — **fail** if not. A cert/name
  mismatch otherwise shows up as browser errors long after a "successful" deploy.
- print `notAfter`, **fail** if already expired, **warn** if under 30 days.
- print the issuer, and warn clearly if it is self-signed or from a Let's Encrypt *staging*
  intermediate, since clients will not trust it.

`tls.key` is never decoded, printed, or written to disk.

**7. Check the license secret** — assert it exists and has a `license.pem` key. Check the key
name only; never decode the value. A wrong key name is a common mistake and the chart's failure
mode for it is opaque.

**8. Check the chart version exists** — `helm repo add teleport https://charts.releases.teleport.dev`,
`helm repo update`, then `helm search repo teleport/teleport-cluster --version "$TELEPORT_VERSION"`
and fail if there is no exact match. Catches a typo in `TELEPORT_VERSION` in two seconds rather
than after a failed pull.

**9. Render the values file** — `envsubst < helm/values.yaml > rendered-values.yaml`, then
`cat` it into the log and the step summary. Showing the rendered file is the clearest possible
explanation of what templating did.

**10. Validate** — `helm lint` and `helm template` against the rendered values. Always runs,
including on `dry_run`.

**11. Stop here if `dry_run`** — `if: inputs.dry_run` on the remaining steps, or an early exit
step. Whichever is easier to read.

**12. Install or upgrade**

```bash
helm upgrade --install teleport teleport/teleport-cluster \
  --version "$TELEPORT_VERSION" \
  --namespace "$K8S_NAMESPACE" \
  --values rendered-values.yaml \
  --wait --timeout 10m
```

Comment must explain that `upgrade --install` means first run and later runs use the same
command, and that this is what makes the workflow safe to re-run.

**13. Wait for the pods** — `kubectl rollout status` for the proxy and auth workloads,
resolved by label selector rather than hardcoded names, so a chart bump does not break it.

**14. Find the address to point DNS at** — poll up to 3 minutes:
- `LoadBalancer` → `.status.loadBalancer.ingress[0].hostname` **or** `.ip` (handle both).
  If still empty after the timeout, **fail with a specific explanation**: this cluster has no
  load balancer controller, and the fix is `SERVICE_TYPE=NodePort` or installing MetalLB.
  A bare timeout here would be baffling; this is the whole point of making it configurable.
- `NodePort` → report `.spec.ports[0].nodePort` plus the node IPs from `kubectl get nodes -o wide`.
- `ClusterIP` → report the ClusterIP and say plainly that external access needs an Ingress or
  port-forward, which is out of scope.

**15. Verify TLS without needing DNS** — the useful trick, and worth a comment explaining it:

```bash
curl --fail --show-error --silent \
  --resolve "${TELEPORT_CLUSTER_NAME}:443:${ADDRESS}" \
  "https://${TELEPORT_CLUSTER_NAME}/webapi/ping"
```

`--resolve` forces the hostname to a specific address, so this tests the real certificate and
SNI **before** DNS is configured. Assert the returned JSON's `server_version` matches
`TELEPORT_VERSION`. If `ADDRESS` is a hostname, resolve it to an IP first. Treat failure here
as a **warning, not an error**, when DNS is not yet configured — the deploy itself succeeded.

**16. Write the step summary** — a short table: cluster name, version, namespace, Helm revision,
service type, **the address to point DNS at**, cert expiry date, and the exact DNS record to
create:

```
Create this DNS record:
  teleport.example.com.  A  203.0.113.10
```

Then: create the first user with
`kubectl exec -n <ns> deploy/<auth> -- tctl users add <name> --roles=editor,access`.
The operator needs this to actually log in, and it is the natural next thing they will want.

**17. On failure, dump diagnostics** — `if: failure()`: `kubectl get all,pvc,events -n <ns>`,
`kubectl describe` non-Ready pods, `kubectl logs --tail=100` for auth and proxy,
`helm status`, `helm history`. Upload as an artifact. Comment explains `if: failure()` and
artifacts.

### 6.4 `helm/values.yaml`

```yaml
chartMode: standalone
clusterName: "${TELEPORT_CLUSTER_NAME}"

enterprise: true
licenseSecretName: "${LICENSE_SECRET_NAME}"

# Use the operator-provisioned certificate. Mutually exclusive with `acme`
# (the chart hard-errors if both are set) and with highAvailability.certManager.
tls:
  existingSecretName: "${TLS_SECRET_NAME}"

proxyListenerMode: multiplex

persistence:
  enabled: true
  volumeSize: "${VOLUME_SIZE}"

service:
  type: "${SERVICE_TYPE}"

highAvailability:
  replicaCount: 1

log:
  level: INFO
  format: json
```

Verified facts the implementer must not contradict:

- `tls.existingSecretName` renders `https_keypairs` pointing at `/etc/teleport-tls/tls.crt`
  and `tls.key`, i.e. a standard `kubernetes.io/tls` secret.
- The rendered config includes **`https_keypairs_reload_interval: 12h`**. Teleport reloads the
  certificate from the secret automatically, so **renewing the cert does not require a pod
  restart or a redeploy.** Say this in `docs/runbook.md` — it is the single most useful
  operational fact in this project.
- `licenseSecretName` mounts to `/var/lib/license/license.pem`; the key inside the secret must
  be exactly `license.pem`.
- `enterprise: true` selects `teleport-ent-distroless:<version>`.
- `replicaCount: 1` is required regardless of TLS mode: `chartMode: standalone` uses a SQLite
  backend on a `ReadWriteOnce` PVC and cannot scale.
- `proxyListenerMode: multiplex` puts everything on port 443. Note in the docs that this
  requires `tsh` for Kubernetes and database access — an acceptable MVP tradeoff for having one
  port to reason about.

**The NodePort trap.** With `service.type: NodePort` the chart still renders
`public_addr: <clusterName>:443`, but clients must connect on the assigned node port
(30000–32767). So when `SERVICE_TYPE=NodePort`, `PUBLIC_ADDR` **must** be set and the values
file must include `publicAddr: ["${PUBLIC_ADDR}"]`. Implement this as a conditional block —
`envsubst` alone cannot express it, so either build the values file with a small
`if` in the run step or keep a second template `values.nodeport.yaml`. Prefer the second: two
readable files beat one clever one. Preflight must fail if `SERVICE_TYPE=NodePort` and
`PUBLIC_ADDR` is unset.

Also document that the chart templates the port list, so the node port **cannot be pinned** via
`service.spec` — it is assigned by Kubernetes and may change if the Service is recreated, which
would require updating `PUBLIC_ADDR`. Another reason `LoadBalancer` is the recommended default.

## 7. `uninstall.yml` and `lint.yml`

### 7.1 `uninstall.yml`

`workflow_dispatch` only. Same `concurrency` group as deploy.

```yaml
inputs:
  confirm:
    description: 'Type the cluster name to confirm'
    required: true
  delete_pvc:
    description: 'Also delete the data volume (DESTROYS all cluster state)'
    type: boolean
    default: false
```

1. Fail unless `confirm == vars.TELEPORT_CLUSTER_NAME`. Comment explains that this is the only
   guard against a mis-click, and that GitHub Environments with required reviewers are the
   heavier-weight option (mention it; do not implement it).
2. `helm uninstall teleport -n "$K8S_NAMESPACE" --ignore-not-found`.
3. If `delete_pvc`: delete the PVC, warning in the log that the cluster's CA and all local
   users are in there and login state cannot be recovered.
4. **Never delete the TLS secret, the license secret, or the namespace.** They are
   operator-owned; the workflow did not create them and must not remove them. Print an explicit
   note saying they were left in place.

### 7.2 `lint.yml`

`on: [pull_request, push (main), workflow_dispatch]`, `runs-on: ubuntu-latest`, no secrets,
no self-hosted runner. Checks:

- `actionlint` over `.github/workflows/` (which also shellchecks inline `run:` blocks)
- `helm lint` + `helm template` on `helm/values.yaml` with placeholder values
- `shellcheck` on `runner/install-runner.sh`
- `yamllint`
- **A guard that no workflow references `secrets.*`** other than the automatic
  `secrets.GITHUB_TOKEN`, enforcing §5.2.
- **A guard that no `pull_request`-triggered workflow uses a self-hosted runner** (§7.3).

For a novice this workflow doubles as the demonstration of the `pull_request` trigger and of CI
as a gate — worth a paragraph in the tutorial explaining that this is why lint runs on
GitHub's runners and deploy does not.

### 7.3 Security requirement — non-negotiable

The self-hosted runner has live credentials to a Kubernetes cluster. **It must never execute
code from a pull request.** Therefore no workflow that uses `runs-on: self-hosted` may be
triggered by `pull_request` or `pull_request_target`, and `lint.yml` enforces this
mechanically. `deploy.yml` and `uninstall.yml` are `workflow_dispatch` only, which satisfies
this by construction; the guard exists to stop a future edit from breaking it.

`docs/setup.md` must state plainly: anyone who can trigger a workflow in this repo can act on
your Kubernetes cluster. Repository write access is the real security boundary.

## 8. `docs/github-actions-101.md` — the tutorial

The operator has never used GitHub Actions. This document teaches the concepts **using the
files in this repository as the worked example**, citing real file and line references so the
abstract term and the concrete line are never more than one glance apart.

Cover, in this order:

1. **What Actions is** — YAML in `.github/workflows/`, run by GitHub when something happens.
2. **Workflow, job, step** — the three levels, mapped onto `deploy.yml`.
3. **Triggers (`on:`)** — `workflow_dispatch` (the button), `pull_request`, `push`. Why deploy
   is dispatch-only here.
4. **Runners and `runs-on:`** — GitHub-hosted vs self-hosted; why deploy needs self-hosted (it
   needs cluster access) and lint does not; what labels are.
5. **Variables vs secrets** — where they live in the UI, why this project uses only variables,
   and that variables are visible in logs while secrets are masked.
6. **Inputs** — `dry_run` and `confirm` as the examples.
7. **Reading a run** — the Actions tab, expanding steps, finding the failing red step first,
   step summaries, artifacts.
8. **Editing safely** — change a variable in the UI (no commit needed) vs change the workflow
   (commit, and lint runs on the PR). Use `dry_run: true` after any edit.
9. **Common failures and what they look like** — bad credentials, missing secret, wrong chart
   version, `<pending>` Service, cert/name mismatch. For each: the log line the operator will
   see and the fix.
10. **What to learn next** — `needs:`, matrices, environments, reusable workflows, OIDC — with
    one sentence each on when they would actually want it.

Constraint: **no YAML in this document that is not also in the repo.** Every snippet is a quote
from a real file, so nothing can drift out of sync or be pasted into the wrong place.

## 9. `runner/install-runner.sh`

Sets up a self-hosted runner on **any** Linux VM — KVM guest, bare metal, LXC, cloud instance.
No hyperscaler assumptions anywhere.

### 9.1 VM requirements (state these at the top of the script and in `docs/setup.md`)

- Linux x86_64 or arm64; Debian/Ubuntu or RHEL family.
- 2 vCPU, 2 GB RAM, 20 GB disk is comfortable. This workload is a few CLI calls.
- **Outbound** HTTPS to `github.com`, `api.github.com`, `*.actions.githubusercontent.com`,
  `charts.releases.teleport.dev`, the container registry, and the Kubernetes API endpoint.
- **No inbound ports.** The runner polls GitHub; nothing connects to it. Say so explicitly —
  operators often assume a runner needs an open port.
- Not a container, for the MVP. Running the runner in Docker/Kubernetes works but adds a layer
  to debug; note it as a later option.

### 9.2 What the script does

1. Detect distro and architecture; refuse clearly on anything unsupported.
2. Install `curl`, `tar`, `git`, `jq`, `openssl`, `gettext` (for `envsubst`).
3. Install pinned `kubectl` and `helm`, verifying checksums. Print the versions installed.
4. Create an unprivileged `github-runner` user with a home directory. Refuse to run the runner
   as root and explain why.
5. Download the `actions/runner` release for the detected arch, verify its SHA-256 against the
   published value, extract it.
6. Register with `config.sh --unattended --replace --labels <label>`, taking the
   **short-lived registration token** as a CLI flag or env var. Explain in a comment where to
   get it: repo → Settings → Actions → Runners → New self-hosted runner. Note that it expires
   in about an hour and is not a long-lived credential.
7. Install and enable the systemd service via the bundled `svc.sh`.
8. Print a summary: runner name, labels, service status, and **an explicit reminder that
   Kubernetes access is a separate step this script does not perform** (§3).

### 9.3 Script quality bar

`set -euo pipefail`; `--help`; idempotent (detect an existing registration and exit cleanly
rather than failing); every prompt-free flag documented; passes `shellcheck`. Verbose,
commented, and readable in one sitting — this script is also teaching material.

## 10. Operator prerequisites — `docs/setup.md`

A numbered checklist, in dependency order, with a copy-pasteable command for each:

1. A Kubernetes cluster, and a namespace for Teleport.
2. In that namespace: a `kubernetes.io/tls` secret with the cert and key —
   `kubectl create secret tls teleport-tls --cert=fullchain.pem --key=privkey.pem -n teleport`.
   The cert must cover `TELEPORT_CLUSTER_NAME`; note that Teleport Application Access would
   also want `*.<clusterName>`, which is out of scope here.
3. In that namespace: the license secret —
   `kubectl create secret generic teleport-license --from-file=license.pem=license.pem -n teleport`.
   Stress that the filename/key **must** be `license.pem`.
4. A VM for the runner (§9.1), with `install-runner.sh` run on it.
5. Kubernetes credentials on that runner — MWI/`tbot`, or a kubeconfig, or an in-cluster
   ServiceAccount. Out of scope for this project; the checklist just states the required
   outcome: `kubectl get ns <namespace>` succeeds when run as the `github-runner` user.
   The minimum RBAC needed in the namespace: full CRUD on the resources the chart creates,
   plus `get` on the two secrets (for the preflight checks), plus `pods/exec` (for
   `tctl users add`). Note that the chart also creates cluster-scoped RBAC, so the credential
   needs `escalate`/`bind` on cluster roles — or the operator pre-creates them and sets
   `rbac.create=false`.
6. The repository variables from §5.1.
7. Run `deploy.yml` with `dry_run: true` first. This validates items 1–6 without changing
   anything, and is the recommended way to check the setup.
8. Run it for real, then create the DNS record the summary tells you to create.
9. Create the first user with the `tctl users add` command from the summary.

## 11. Acceptance criteria

1. `deploy.yml` with `dry_run: true` passes on a correctly prepared cluster and installs nothing.
2. `deploy.yml` for real brings up a running Teleport cluster serving the operator's
   certificate; the step summary names the address to point DNS at.
3. Re-running `deploy.yml` succeeds and causes no pod churn.
4. Removing any one prerequisite (missing namespace, missing/mis-keyed license secret,
   cert whose SAN does not match, bad `TELEPORT_VERSION`, broken credentials,
   `NodePort` without `PUBLIC_ADDR`) produces a **specific, actionable** error in preflight —
   not a Helm timeout. Each case should be listed in the tutorial's §9.
5. `SERVICE_TYPE=NodePort` deploys successfully and reports node IP + port.
6. With no load balancer controller and `SERVICE_TYPE=LoadBalancer`, the workflow fails with a
   message naming both fixes.
7. `uninstall.yml` removes the release, leaves both secrets and the namespace intact, and is
   re-runnable.
8. `lint.yml` passes on a PR, and its two guards fail when deliberately violated (a workflow
   referencing `secrets.FOO`, and a `pull_request`-triggered self-hosted job).
9. Zero GitHub secrets are configured or referenced anywhere.
10. An operator who has never used GitHub Actions can go from an empty repo to a running
    cluster using only `README.md` → `docs/setup.md`.

## 12. Implementation notes

- Pin third-party actions to commit SHAs. `actions/checkout` and `actions/upload-artifact` are
  the only ones needed.
- Resolve workload names by label selector, never hardcoded (`teleport-cluster-auth` etc. can
  change across chart versions).
- `helm upgrade --install` everywhere; every workflow re-runnable.
- Fail fast and loudly in preflight; every check's failure message must say what to fix and
  where, not just what went wrong.
- Never print the contents of `tls.key` or `license.pem`. `tls.crt` is public and is fine to
  inspect.
- Comment density in the workflows should be roughly one comment per step, explaining *why*.
  This is the one project where over-commenting is correct.
