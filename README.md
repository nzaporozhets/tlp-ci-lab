# Deploy a Teleport cluster with GitHub Actions

Press a button in the GitHub Actions tab; get a Teleport Enterprise cluster
running in your Kubernetes cluster.

**Zero GitHub secrets.** No Terraform, no cloud APIs, no DNS automation. Five
files of workflow and values, and four documents that explain them.

This repository is also a **tutorial**. It is written for an operator who has
never used GitHub Actions, so the workflows are heavily commented and
[`docs/github-actions-101.md`](docs/github-actions-101.md) teaches the concepts
using these exact files as the worked example.

---

## Start here

1. **Never used GitHub Actions?** Read
   [`docs/github-actions-101.md`](docs/github-actions-101.md) — about twenty
   minutes, and it makes everything below make sense.
2. **Setting this up?** Follow [`docs/setup.md`](docs/setup.md) top to bottom. It
   is a numbered checklist with a copy-pasteable command for each step.
3. **Already running?** [`docs/runbook.md`](docs/runbook.md) covers upgrades,
   certificate renewal, adding users, uninstalling and troubleshooting.

---

## What is in here

```
.github/workflows/
  deploy.yml            install or upgrade the cluster (button-only)
  uninstall.yml         remove it (button-only, typed confirmation)
  lint.yml              checks on every pull request; GitHub-hosted, no secrets
helm/
  values.yaml           chart configuration; ${PLACEHOLDERS} filled in at run time
  values.nodeport.yaml  the same, for clusters with no load balancer
runner/
  install-runner.sh     set up the self-hosted runner on any Linux VM
docs/
  github-actions-101.md the tutorial
  setup.md              one-time prerequisites checklist
  runbook.md            day-two operations
SPEC-MVP.md             the specification this implements
SPEC.md                 the earlier, larger specification (see below)
```

---

## How it works, in one paragraph

You create a namespace, a TLS Secret and a licence Secret in your Kubernetes
cluster by hand, and you install a **self-hosted runner** — a small agent on a VM
you control — that already has working `kubectl` access. Everything else the
pipeline needs comes from **repository variables**, which are settings in the
GitHub UI, not secrets. When you press *Run workflow*, the runner checks all of
those prerequisites, renders `helm/values.yaml`, runs `helm upgrade --install`,
waits for the pods, works out the address you should point DNS at, and tells you
on the summary page.

---

## Why there are no GitHub secrets

Not a slogan — a structural property, and the reason this project is smaller than
it looks like it should be.

* **Your TLS certificate and private key** live in a Kubernetes Secret that you
  create. The workflow asserts it exists and inspects the *public* certificate
  (names, expiry, issuer). It never decodes the private key.
* **Your Teleport licence** likewise. The workflow checks that the Secret has a
  key named `license.pem`. It never reads the value.
* **Your Kubernetes credentials** live only on the runner VM. The workflow's whole
  contract with the runner is *"`kubectl` and `helm` are on `PATH` and already
  authenticated"* — it never reads, writes or refreshes a credential, and makes no
  assumption about whether they come from Teleport Machine & Workload Identity, a
  kubeconfig, or a ServiceAccount.

`lint.yml` enforces this mechanically: a guard fails the build if any workflow
references `secrets.*` (other than the automatic `secrets.GITHUB_TOKEN`).

Because the certificate is provisioned in advance, **nothing in the deploy depends
on DNS resolving.** That single decision removes the ACME rate limits, the
load-balancer-versus-certificate ordering problem, and the DNS-before-certificate
dance that a Let's Encrypt setup needs.

---

## Security, in three lines

**Anyone who can trigger a workflow in this repository can act on your Kubernetes
cluster** — the self-hosted runner holds live credentials. Repository write access
is the real security boundary. No workflow that runs on that runner may be
triggered by a pull request, and `lint.yml` fails the build if a future edit ever
breaks that rule. Details in [`docs/setup.md`](docs/setup.md).

---

## Scope

**In:** one Teleport Enterprise cluster, deployed and upgraded from a button, with
a pre-provisioned certificate, on any Kubernetes cluster (`LoadBalancer`,
`NodePort` or `ClusterIP`).

**Out:** Teleport agents of any kind, Terraform, cloud APIs, DNS automation,
certificate issuance, SSO/RBAC configuration, high availability, backup and
restore. [`docs/runbook.md`](docs/runbook.md) lists these with a pointer for each.

The larger, more ambitious earlier version of this project — four workflows, two
Terraform modules, six scripts, ACME certificates and two Teleport agents — is
preserved on the **`master`** branch, and its specification is
[`SPEC.md`](SPEC.md).
