# Runbook — day-two operations

Everything you will actually need after the first successful deploy.

First-time setup is in [`setup.md`](setup.md). If you have never used GitHub
Actions, [`github-actions-101.md`](github-actions-101.md) explains the mechanics.

---

## The single most useful fact in this project

**Renewing your TLS certificate does not require a redeploy, a restart, or this
pipeline at all.**

The chart configures Teleport with:

```yaml
      https_keypairs:
      - cert_file: /etc/teleport-tls/tls.crt
        key_file: /etc/teleport-tls/tls.key
      https_keypairs_reload_interval: 12h
```

Teleport re-reads the certificate files every 12 hours. The files come from your
Kubernetes Secret, and Kubernetes propagates Secret changes into running pods
automatically. So updating the Secret is the whole job — see
[Renew the certificate](#renew-the-certificate) below.

---

## Contents

* [Deploy or re-deploy](#deploy-or-re-deploy)
* [Upgrade Teleport](#upgrade-teleport)
* [Renew the certificate](#renew-the-certificate)
* [Add a user](#add-a-user)
* [Change a setting](#change-a-setting)
* [Uninstall](#uninstall)
* [Recover the data volume after an uninstall](#recover-the-data-volume-after-an-uninstall)
* [Troubleshooting](#troubleshooting)
* [Things this project deliberately does not do](#things-this-project-deliberately-does-not-do)

---

## Deploy or re-deploy

**Actions → Deploy Teleport cluster → Run workflow.**

Tick `dry_run` to validate without changing anything. Leave it unticked to
install or upgrade.

The workflow is safe to run repeatedly. It uses `helm upgrade --install`, so the
first run and every later run are the same command, and re-running with no
changes produces no pod churn: Helm compares the rendered manifests with what is
already there and does nothing if they match.

**When in doubt, re-run it.** That is the whole point of a pipeline like this.

---

## Upgrade Teleport

1. Change the `TELEPORT_VERSION` repository variable
   (**Settings → Secrets and variables → Actions → Variables**). No commit
   needed — variables are settings, not code.
2. Run **Deploy Teleport cluster** with `dry_run` ticked. This confirms the new
   chart version actually exists before you touch anything.
3. Run it again with `dry_run` unticked.

`TELEPORT_VERSION` sets both the chart version and the Teleport version, so they
can never drift apart.

Things worth knowing:

* **Do not skip major versions.** Teleport supports upgrading one major version at
  a time (17 → 18, not 17 → 19). To go further, do it in steps, deploying and
  verifying each one.
* **There will be a brief outage.** `chartMode: standalone` runs a single auth pod
  on a ReadWriteOnce volume, and the chart uses the `Recreate` strategy for it:
  the old pod stops before the new one starts. Expect a minute or two of
  unavailability. Highly-available upgrades need an external backend, which is out
  of scope here.
* **Downgrades are not supported by Teleport.** The auth server may migrate the
  backend on start-up. Take a backup first if you are experimenting (see below).
* The final step of the workflow calls `/webapi/ping` and compares the reported
  version with `TELEPORT_VERSION`, so the log tells you whether the new version is
  really the one answering.

### Back up before an upgrade

There is no backup automation in this project. The pragmatic version:

```bash
# Export the cluster's configuration resources.
kubectl exec -n teleport deploy/teleport-auth -- \
  tctl get users,roles,connectors,tokens --with-secrets > teleport-backup.yaml
```

Keep that file somewhere safe — it contains secrets. It does not include the
certificate authorities, so it is a configuration backup, not a full restore. For
that, snapshot the PersistentVolume with whatever your storage provider offers.

---

## Renew the certificate

Update the Secret in place. Do **not** run the deploy workflow.

```bash
kubectl create secret tls teleport-tls \
  --cert=fullchain.pem --key=privkey.pem \
  -n teleport \
  --dry-run=client -o yaml | kubectl apply -f -
```

(`create --dry-run=client | apply` is the usual trick for "create or replace a
Secret": plain `kubectl create` fails if it already exists.)

Then wait. Two delays add up:

1. Kubernetes updates the file inside the running pod — up to about a minute.
2. Teleport re-reads it — up to 12 hours
   (`https_keypairs_reload_interval: 12h`).

Verify from outside, without trusting the browser cache:

```bash
echo | openssl s_client -connect teleport.example.com:443 \
  -servername teleport.example.com 2>/dev/null \
  | openssl x509 -noout -dates -subject
```

If you need the new certificate live immediately, restart the proxy pods — but
know that this is an impatience workaround, not a requirement:

```bash
kubectl rollout restart deployment -n teleport \
  -l app.kubernetes.io/name=teleport-cluster,app.kubernetes.io/component=proxy
```

**A note on expiry warnings.** `deploy.yml` warns when the certificate has less
than 30 days left and fails outright if it has already expired. That check only
runs when you deploy, so it is a safety net, not a monitor. Nothing in this
project watches your certificate — put its expiry date in your calendar, or
automate renewal with `certbot` and the `kubectl apply` above.

---

## Add a user

Every Teleport user is created against the auth pod:

```bash
kubectl exec -n teleport deploy/teleport-auth -- \
  tctl users add alice --roles=editor,access
```

`editor,access` is the built-in "administrator" pair: `access` grants access to
resources, `editor` grants the right to change cluster configuration. For everyone
who is not an administrator, use `--roles=access` and define your own roles.

Other things you will want:

```bash
# List users.
kubectl exec -n teleport deploy/teleport-auth -- tctl users ls

# Remove a user.
kubectl exec -n teleport deploy/teleport-auth -- tctl users rm alice

# Reset someone's password and second factor.
kubectl exec -n teleport deploy/teleport-auth -- tctl users reset alice

# A shell in the auth pod, for anything else.
kubectl exec -it -n teleport deploy/teleport-auth -- /bin/sh
```

If `deploy/teleport-auth` does not exist, find the real name — it is derived from
the Helm release name and could change with a chart version:

```bash
kubectl get deployment -n teleport \
  -l app.kubernetes.io/name=teleport-cluster,app.kubernetes.io/component=auth
```

---

## Change a setting

**A repository variable** (`SERVICE_TYPE`, `VOLUME_SIZE`, `TELEPORT_VERSION`, …):
edit it in **Settings → Secrets and variables → Actions → Variables** and re-run
the deploy workflow. No commit, no pull request, no lint.

**Something not exposed as a variable** (log level, a chart feature this MVP does
not surface): edit [`helm/values.yaml`](../helm/values.yaml) — and
[`helm/values.nodeport.yaml`](../helm/values.nodeport.yaml), which is a near-copy;
keeping them in step is the price of having two readable files instead of one
clever one. Commit on a branch, open a pull request so `lint.yml` renders the
chart with your change, merge, then deploy with `dry_run` ticked before deploying
for real.

The chart's full set of options is documented at
<https://goteleport.com/docs/reference/helm-reference/teleport-cluster/>.

**One setting you cannot change:** `TELEPORT_CLUSTER_NAME`. Teleport bakes it into
the cluster's certificate authorities on first start. Changing it gives you a new
cluster, not a renamed one — every user and every enrolled resource would have to
be recreated.

**One setting you must not change:** `highAvailability.replicaCount` and
`proxy.highAvailability.replicaCount` must stay at 1. `chartMode: standalone`
keeps all state in SQLite on a ReadWriteOnce volume, which only one node can
mount for writing. `deploy.yml` and `lint.yml` both fail if the rendered
manifests ask for more than one replica.

---

## Uninstall

**Actions → Uninstall Teleport cluster → Run workflow.** You must type the
cluster name into the `confirm` field; anything else and the run stops before
touching the cluster.

| Input | Effect |
|---|---|
| `confirm` | Must exactly equal `TELEPORT_CLUSTER_NAME`. The only guard against a mis-click. |
| `delete_pvc` | Unticked (default): the underlying data volume is retained. Ticked: **the data is destroyed**, along with Teleport's certificate authorities and every local user. |

### What it never touches

* the TLS Secret
* the licence Secret
* the namespace itself

The workflow did not create those, so it does not delete them, and it prints a
note saying so. That also means re-running the deploy workflow brings the cluster
straight back up with no manual preparation.

If you really want them gone:

```bash
kubectl delete namespace teleport   # takes both Secrets with it
```

Remember to delete your DNS record too. This project never touches DNS.

### About the data volume

Something slightly surprising, and worth knowing: the chart's
PersistentVolumeClaim is an ordinary Helm-managed resource, so **`helm uninstall`
always deletes the claim** — there is no chart option to spare it.

So when `delete_pvc` is unticked, the workflow protects your data a level lower
down: before uninstalling, it sets the bound PersistentVolume's reclaim policy to
`Retain`. The claim goes away, but the volume and everything on it survive in the
`Released` state. The run summary tells you the volume's name.

That step is best-effort: PersistentVolumes are cluster-scoped objects, and the
runner's credentials may not be allowed to patch them. If so you get a warning
saying the data will be deleted with the claim.

---

## Recover the data volume after an uninstall

Only relevant if you uninstalled with `delete_pvc` unticked *and* the workflow
reported that it set the volume to `Retain`. This is a manual administrative
operation.

```bash
# 1. Find the released volume. Note its name and capacity.
kubectl get pv | grep Released

# 2. Clear its claim reference, so Kubernetes considers it Available again.
#    A Released volume remembers the claim that used to own it and will not bind
#    to a new one until you remove that memory.
kubectl patch pv <volume-name> -p '{"spec":{"claimRef": null}}'

# 3. Re-create a claim with the SAME NAME the chart uses -- which is the Helm
#    release name, `teleport` -- bound explicitly to that volume.
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: teleport
  namespace: teleport
spec:
  accessModes: ["ReadWriteOnce"]
  volumeName: <volume-name>
  resources:
    requests:
      storage: 10Gi
EOF

# 4. Tell the chart to adopt that claim instead of creating its own, by adding
#    this to helm/values.yaml (both templates):
#      persistence:
#        existingClaimName: "teleport"
#    then run the deploy workflow.
```

If any of that feels uncomfortable, the honest advice is: take configuration
backups with `tctl get` (see [Upgrade Teleport](#upgrade-teleport)) and treat a
lost volume as "recreate the cluster and re-enrol", which for a small deployment
is often faster than volume surgery.

---

## Troubleshooting

Start on the run's page in the Actions tab and find the **first** red step —
later failures are usually consequences of it. When a deploy fails, the workflow
attaches a `teleport-deploy-diagnostics` artifact to the run with everything
below already collected.

### `The runner's Kubernetes credentials are not working`

The most common failure, and the least to do with this project. On the runner VM:

```bash
sudo -u github-runner kubectl cluster-info
sudo -u github-runner kubectl get ns
sudo -u github-runner env | grep -i kube
```

If short-lived credentials are in use (`tbot`, cloud SSO), check that whatever
renews them is running. See [`setup.md`](setup.md) step 5.

### The Service sits at `EXTERNAL-IP <pending>`

Your cluster has no load balancer controller: nothing is watching for
`LoadBalancer` Services, so none is ever created. Normal on kubeadm, k3s without
servicelb, and bare metal.

Two fixes, both fine:

1. Set `SERVICE_TYPE=NodePort` and also set `PUBLIC_ADDR` — see
   [`setup.md`](setup.md) step 6.
2. Install MetalLB (or your platform's equivalent) and re-run.

`deploy.yml` detects this after three minutes and says both.

### Pods are `Pending`

```bash
kubectl get pods -n teleport
kubectl describe pod -n teleport <pod>
kubectl get pvc -n teleport
kubectl get events -n teleport --sort-by=.lastTimestamp
```

Usually one of:

* **No volume.** The PVC is `Pending` because the cluster has no default
  StorageClass, or the one named in `STORAGE_CLASS` does not exist. Check
  `kubectl get storageclass`.
* **No room.** `describe` says `Insufficient cpu` or `Insufficient memory`.
* **Cannot pull the image.** `ImagePullBackOff` — the node cannot reach
  `public.ecr.aws`.

### The auth pod crash-loops

```bash
kubectl logs -n teleport deploy/teleport-auth --tail=100
kubectl logs -n teleport deploy/teleport-auth --tail=100 --previous
```

`--previous` is the important one: a crashed container's useful output is in the
*previous* instance, not the one that is about to start.

Likely causes:

* **Licence problem.** Anything mentioning `license` or
  `/var/lib/license/license.pem` means the Secret's key is not named exactly
  `license.pem`, or the file is not a valid licence.
  `deploy.yml` checks the key name, so this is usually the file itself.
* **Backend migration.** After a version change, give it a few minutes before
  concluding it is stuck.

### `Error: UPGRADE FAILED: another operation is in progress`

A previous Helm run was interrupted. Look at the release's state:

```bash
helm history teleport -n teleport
```

If the newest revision is `pending-install` or `pending-upgrade`, roll back to the
last good one:

```bash
helm rollback teleport <last-good-revision> -n teleport
```

If the *first* install is what got stuck, there is nothing to roll back to — run
the uninstall workflow (leaving `delete_pvc` unticked) and deploy again.

This is what `concurrency: cancel-in-progress: false` in both workflows exists to
prevent: two runs are queued, never overlapped.

### A pre-install Job fails

The chart runs `teleport-auth-test` and `teleport-proxy-test` as Helm
`pre-install`/`pre-upgrade` hooks. They validate the generated Teleport
configuration before anything real is created. If one fails, its logs contain the
actual configuration error:

```bash
kubectl logs -n teleport job/teleport-auth-test
```

### Clients cannot connect, but the pods are healthy

Work outward from the cluster:

```bash
# 1. Does the proxy answer at all, from inside the cluster?
kubectl port-forward -n teleport service/teleport 8443:443
curl -k https://localhost:8443/webapi/ping

# 2. Does it answer at its external address, with the right certificate?
#    --resolve tests the certificate and SNI without relying on DNS.
curl --resolve teleport.example.com:443:203.0.113.10 \
  https://teleport.example.com/webapi/ping

# 3. Does DNS point at that address?
dig +short teleport.example.com
```

If step 1 works and step 2 does not, the problem is between the internet and your
Service: a firewall, a security group, or a missing load balancer.

For NodePort, remember that the port is **not** 443 — use the node port from the
run summary in both the `--resolve` argument and the URL.

### `tsh` can connect but Kubernetes or database access does not work

Expected: this MVP sets `proxyListenerMode: multiplex`, which serves every
Teleport protocol on the single port 443 using ALPN/SNI. That is one port to open
and reason about, at the cost of requiring `tsh` (or Teleport Connect) as the
client for Kubernetes and database access rather than a direct connection to a
dedicated port. Use `tsh kube login` and `tsh db connect`.

### Useful one-liners

```bash
# Everything, at a glance.
kubectl get all,pvc -n teleport

# Which Helm revision is live, and what changed.
helm history teleport -n teleport
helm get values teleport -n teleport

# Follow the logs of both components at once.
kubectl logs -n teleport -l app.kubernetes.io/name=teleport-cluster \
  --all-containers --prefix --follow --tail=20

# Read Teleport's generated configuration -- often the fastest way to answer
# "did my values change actually take effect?"
kubectl get configmap -n teleport teleport-proxy -o jsonpath='{.data.teleport\.yaml}'

# What the cluster reports about itself, from outside.
curl -s https://teleport.example.com/webapi/ping | jq .
```

---

## Things this project deliberately does not do

Knowing where the edges are saves time looking for features that are not there.

| Not here | What to do instead |
|---|---|
| Issue or renew certificates | Your own CA or `certbot`, then update the Secret (above). |
| Manage DNS | Create the record the deploy summary tells you to create. |
| Create the namespace or the two Secrets | [`setup.md`](setup.md) steps 1–3, by hand. |
| Manage the runner's Kubernetes credentials | [`setup.md`](setup.md) step 5. |
| Teleport agents (kube, ssh, app, db) | Not in this MVP. The v1 branch (`master`) has an example. |
| SSO, RBAC roles, access requests | `tctl create -f` against your own resource files. |
| High availability | Needs an external backend and a different `chartMode`. |
| Backup and restore | `tctl get` for configuration; your storage provider for the volume. |
| Monitoring or alerting on certificate expiry | Your own monitoring. The deploy-time warning is a safety net only. |
