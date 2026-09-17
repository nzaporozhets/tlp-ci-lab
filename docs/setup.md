# One-time setup checklist

Work through this once, in order. Each step depends on the ones before it.

You will finish with a Teleport Enterprise cluster you can deploy and re-deploy
by pressing a button in the GitHub Actions tab.

If you have never used GitHub Actions, you do not need to read
[`github-actions-101.md`](github-actions-101.md) first — but read it before you
edit any workflow.

---

## Before you start: what you need to have

| Thing | Why |
|---|---|
| A Kubernetes cluster you can already reach with `kubectl` | This project deploys into it; it does not create it. |
| A Teleport Enterprise licence file (`license.pem`) | `enterprise: true` requires one. Get it from your Teleport account. |
| A TLS certificate and private key for your chosen hostname | This project never issues certificates. |
| Control of the DNS zone for that hostname | You will create one record by hand at the end. |
| A Linux VM to run the GitHub Actions runner on | Step 4. |
| Write access to this GitHub repository | See the security note at the bottom. |

---

## A note on how this project treats credentials

**The pipeline holds no credentials at all.** There are zero GitHub secrets.

* Your Teleport licence and your TLS private key live in Kubernetes Secrets that
  **you** create (steps 2 and 3). The workflow checks they exist and never reads
  their contents.
* Your Kubernetes credentials live **only on the runner VM** (step 5). The
  workflow assumes `kubectl` already works there and never touches, refreshes or
  inspects the credential.

"Avoid secrets" refers to the *pipeline's* exposure surface. You still have
secrets — they just never pass through GitHub.

---

## 1. A cluster and a namespace

The namespace must exist before the first deploy. The workflow deliberately does
**not** create it, because it is where your two hand-made Secrets live: if it is
missing, something is wrong with your setup and inventing an empty one would just
move the error further away from its cause.

```bash
kubectl create namespace teleport
```

Use whatever name you like; you will put it in the `K8S_NAMESPACE` variable in
step 6.

---

## 2. The TLS certificate Secret

Teleport will serve this certificate to every client. This project does not
issue or renew certificates — get one from Let's Encrypt (`certbot`), your
internal CA, your existing certificate management, or generate a self-signed one
for a first experiment.

**The certificate must cover the exact hostname you are going to use as the
cluster name.** `deploy.yml` checks this and refuses to deploy if it does not,
because a mismatch otherwise turns into browser errors for every user, discovered
much later.

```bash
kubectl create secret tls teleport-tls \
  --cert=fullchain.pem \
  --key=privkey.pem \
  -n teleport
```

Notes:

* Use the **full chain** (leaf + intermediates) as `--cert`, not just the leaf.
  Without the intermediates, some clients will reject the certificate even though
  a browser accepts it.
* `kubectl create secret tls` sets the Secret's type to `kubernetes.io/tls` and
  puts the data under the keys `tls.crt` and `tls.key`. The Helm chart expects
  exactly that, and `deploy.yml` checks the type and both key names.
* If you also want Teleport **Application Access** later, that needs a wildcard
  certificate covering `*.<clusterName>` as well. Out of scope here, but worth
  knowing before you buy a certificate.
* A self-signed certificate works — Teleport will start and serve it — but
  clients will not trust it. `deploy.yml` prints a warning when it detects one,
  and another for Let's Encrypt *staging* certificates, which are also untrusted.

---

## 3. The licence Secret

```bash
kubectl create secret generic teleport-license \
  --from-file=license.pem=/path/to/your/license.pem \
  -n teleport
```

**The key inside the Secret must be named exactly `license.pem`.** The chart
mounts this Secret at `/var/lib/license/license.pem` and tells Teleport to read
that path. If the key has any other name — `license`, `teleport.pem`,
`license.pem.txt` — the file lands under the wrong name and the auth pod
crash-loops with a message that never mentions the Secret.

The `--from-file=license.pem=<path>` form above sets the key name explicitly,
which is why it is written that way. `--from-file=/path/to/license.pem` would
also work *if* your file happens to be called `license.pem`, and would silently
produce the wrong key name if it is not.

`deploy.yml` checks the key name for you. It never reads the value.

---

## 4. A VM for the runner, and the runner itself

GitHub's own runners live in GitHub's cloud and cannot reach your Kubernetes API
server. So this project needs a **self-hosted runner**: a machine you control
that runs a small agent, polls GitHub for work, and executes it.

### VM requirements

* Linux, x86_64 or arm64. Debian/Ubuntu or the RHEL family.
* 2 vCPU, 2 GB RAM, 20 GB disk is comfortable. The workload is a handful of CLI
  calls, not a build.
* **Outbound** HTTPS to `github.com`, `api.github.com`,
  `*.actions.githubusercontent.com`, `charts.releases.teleport.dev`, your
  container registry, and your Kubernetes API endpoint.
* **No inbound ports at all.** The runner connects *out* to GitHub and polls for
  jobs; nothing ever connects *in* to it. Operators often assume a runner needs
  an open port or a public IP. It does not. You can put it behind NAT with no
  inbound firewall rules whatsoever.
* Not a container, for this MVP. Running the runner in Docker or Kubernetes works
  fine and is a reasonable later step, but it adds a layer to debug.

Any Linux VM will do: a KVM guest, a bare-metal box, an LXC container, a cloud
instance. There are no hyperscaler assumptions anywhere in this project.

### Get a registration token

In this repository on GitHub:

**Settings → Actions → Runners → New self-hosted runner**

GitHub shows you a set of commands. You only need the token from the
`./config.sh --token ...` line. It **expires in about an hour** and can only
register a runner — it is not a long-lived credential, and it is not a GitHub
secret.

### Run the installer

Copy [`runner/install-runner.sh`](../runner/install-runner.sh) to the VM and run
it as root:

```bash
sudo ./install-runner.sh \
  --url    https://github.com/<owner>/<repo> \
  --token  <registration-token> \
  --labels self-hosted,linux,teleport-mvp
```

| Flag | Meaning |
|---|---|
| `--url` | This repository's URL. |
| `--token` | The registration token from above. You can pass it as the `RUNNER_TOKEN` environment variable instead, to keep it out of your shell history. |
| `--labels` | Comma-separated labels. **The third one must match the `RUNNER_LABEL` variable you set in step 6**, because that is how `deploy.yml` finds this runner. |
| `--runner-name` | Optional display name. Defaults to the machine's hostname. |
| `--help` | Full flag reference. |

The script installs `kubectl`, `helm`, `jq`, `openssl` and `envsubst`, creates an
unprivileged `github-runner` user, registers the runner and installs a systemd
service. It is safe to re-run: it detects an existing registration and exits
cleanly instead of failing.

Check it worked: **Settings → Actions → Runners** should show your runner as
**Idle**.

**The installer does not set up Kubernetes access.** That is the next step, and
it is deliberately separate.

---

## 5. Kubernetes credentials on the runner

This is the step most likely to trip you up, and the one this project has the
least to say about — on purpose.

**The required outcome, and the whole contract:** running this as the
`github-runner` user on the runner VM must succeed.

```bash
sudo -u github-runner kubectl get ns teleport
```

How you achieve that is your choice, and the workflow makes no assumption about
it. Common options:

* **Teleport Machine & Workload Identity (`tbot`)** from a *separate* Teleport
  cluster. This is the nicest answer: the runner gets short-lived, automatically
  renewed credentials and there is no long-lived kubeconfig on disk. It does mean
  you need an existing Teleport cluster to issue them.
* **A kubeconfig file** in `/home/github-runner/.kube/config`, or pointed to by
  `KUBECONFIG`. Simple; it is a long-lived credential on disk, so treat the VM
  accordingly.
* **An in-cluster ServiceAccount**, if the runner itself runs inside the target
  cluster.

Two things that catch people out:

* `KUBECONFIG` must be set for the **`github-runner` user's service
  environment**, not just for your interactive shell. The runner runs as a
  systemd service and does not read your `~/.bashrc`.
* If your credentials are short-lived (MWI, cloud SSO, `tbot`), make sure the
  thing that renews them is running as a service too. A deploy that worked
  yesterday and fails today with "credentials are not working" is almost always
  an expired credential.

### Minimum RBAC in the namespace

The credential needs, in `K8S_NAMESPACE`:

* Full CRUD on the resources the chart creates: `deployments`, `services`,
  `configmaps`, `serviceaccounts`, `persistentvolumeclaims`, `jobs`, `pods`,
  `secrets`, `roles`, `rolebindings`.
* `get` on the two Secrets from steps 2 and 3, for the preflight checks.
* `create` on `pods/exec`, so you can run `tctl users add` (step 9).

`deploy.yml` checks a representative subset of these with `kubectl auth can-i`
and tells you exactly which ones are missing.

### Cluster-scoped RBAC

The chart also creates a `ClusterRole` and two `ClusterRoleBindings`. Kubernetes
will not let you grant permissions you do not hold yourself, so the credential
needs `escalate` and `bind` on cluster roles — or, if that is unacceptable in
your environment, pre-create those objects yourself and add
`rbac.create=false` to [`helm/values.yaml`](../helm/values.yaml).

`deploy.yml` reports this one as a **warning** rather than an error, because it
cannot tell from the outside which of the two arrangements you chose.

---

## 6. The repository variables

**Settings → Secrets and variables → Actions → *Variables* tab** →
*New repository variable*, once per row.

Note the tab. Variables and secrets live on the same page but are different
things: variables are visible in run logs (which is why this project prints them
deliberately), secrets are masked. **This project uses no secrets at all.**

| Variable | Example | Required | Notes |
|---|---|---|---|
| `TELEPORT_VERSION` | `18.11.1` | yes | Chart version *and* Teleport version — one source of truth. |
| `TELEPORT_CLUSTER_NAME` | `teleport.example.com` | yes | The DNS name users will type. **Effectively immutable**: Teleport bakes it into the cluster's certificate authority on first start. Changing it means a new cluster. |
| `K8S_NAMESPACE` | `teleport` | yes | From step 1. Must already exist and already contain both Secrets. |
| `TLS_SECRET_NAME` | `teleport-tls` | yes | From step 2. |
| `LICENSE_SECRET_NAME` | `teleport-license` | yes | From step 3. |
| `RUNNER_LABEL` | `teleport-mvp` | yes | Must match a label you gave the runner in step 4. |
| `SERVICE_TYPE` | `LoadBalancer` | no (default `LoadBalancer`) | `LoadBalancer`, `NodePort` or `ClusterIP`. |
| `PUBLIC_ADDR` | `teleport.example.com:32443` | **only if** `SERVICE_TYPE=NodePort` | See the note below. |
| `STORAGE_CLASS` | `standard` | no | Leave unset to use the cluster's default StorageClass. That is the normal case. |
| `VOLUME_SIZE` | `10Gi` | no (default `10Gi`) | Size of the data volume. |

### Which `SERVICE_TYPE` should you pick?

* **`LoadBalancer`** — the recommended default. Works on any cloud, and on
  bare metal if you have MetalLB or similar. Your cluster gets an external IP or
  hostname, and you point DNS at it.
* **`NodePort`** — use this if the Service otherwise sits at
  `EXTERNAL-IP <pending>` forever, which means your cluster has no load balancer
  controller. Common on kubeadm, k3s without servicelb, and home labs.
  **`PUBLIC_ADDR` is then mandatory**, because Kubernetes exposes Teleport on a
  random port in the 30000–32767 range while the chart still advertises port 443
  to clients. The full explanation is at the top of
  [`helm/values.nodeport.yaml`](../helm/values.nodeport.yaml).

  Chicken and egg: you do not know the port until you have deployed once. So
  deploy with `SERVICE_TYPE=NodePort` and `PUBLIC_ADDR` set to any placeholder
  such as `teleport.example.com:30000`; the run summary tells you the real port;
  set `PUBLIC_ADDR` properly and re-run. The workflow warns you when the two
  disagree.
* **`ClusterIP`** — in-cluster only. Fine for a look around with
  `kubectl port-forward`, not useful for real access without an Ingress.

---

## 7. Dry run

**Actions → Deploy Teleport cluster → Run workflow → tick `dry_run` → Run.**

This validates steps 1–6 without changing anything: it checks the tools on your
runner, its Kubernetes credentials and permissions, the namespace, both Secrets,
your certificate's names and expiry, that the chart version exists, and that the
values render into a valid chart.

**This is the recommended way to check your setup.** It is completely safe and
you can run it as often as you like. If it fails, the failing step names what to
fix; [`github-actions-101.md`](github-actions-101.md) section 9 lists the common
ones.

---

## 8. Deploy for real, then create the DNS record

Run the same workflow with `dry_run` **unticked**.

When it finishes, the run's summary page tells you the exact DNS record to
create, for example:

```
teleport.example.com.  A  203.0.113.10
```

Create that record in your DNS zone. Nothing in this project touches DNS.

Because the certificate was provisioned in advance, **nothing in the deploy
depended on DNS resolving** — only clients do. That is why this MVP is so much
simpler than an ACME-based one, and it is also why the workflow can verify TLS
before the record exists (it uses `curl --resolve`).

---

## 9. Create your first user

A fresh Teleport cluster has no users. The run summary gives you the exact
command; it looks like this:

```bash
kubectl exec -n teleport deploy/teleport-auth -- \
  tctl users add alice --roles=editor,access
```

It prints a single-use invitation link. Open it, set a password, enrol a second
factor. The link expires, so use it promptly.

Then log in:

```bash
tsh login --proxy=teleport.example.com:443 --user=alice
```

(For a NodePort cluster, use the port from the summary instead of 443.)

---

## Security note — please read this one

**Anyone who can trigger a workflow in this repository can act on your Kubernetes
cluster.**

The self-hosted runner holds live cluster credentials. `deploy.yml` runs on it.
Anyone who can push to this repository, or press the "Run workflow" button, can
therefore run arbitrary commands with those credentials.

**Repository write access is the real security boundary here.** Not the runner,
not the RBAC, not the absence of GitHub secrets. Treat the list of people with
write access to this repository as the list of people who administer your
Teleport cluster.

Two consequences baked into this project:

1. **No workflow that runs on the self-hosted runner may be triggered by a pull
   request.** A pull request can come from anyone and can modify the workflow file
   itself, so this would hand a stranger your cluster. `lint.yml` checks this
   mechanically on every pull request and fails if a future edit breaks it.
2. **`deploy.yml` and `uninstall.yml` are button-only** (`workflow_dispatch`), so
   no push can change your cluster by accident.

If more than one or two people have write access, consider adding branch
protection on `main` and a GitHub **Environment** with required reviewers on the
deploy job — a run then pauses until a named human approves it. Both are
mentioned in [`github-actions-101.md`](github-actions-101.md) section 10.
