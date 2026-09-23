# GitHub Actions, taught with this repository

This document assumes you have **never used GitHub Actions**. It teaches the
concepts you need, and every example is a real quotation from a file in this
repository, cited as `file:line`. Nothing here is invented, so nothing here can
drift out of sync with the code or be pasted into the wrong place.

Read it once, top to bottom — about twenty minutes. You do not need to memorise
anything; you need to recognise the words when you next see them.

## Contents

1. [What GitHub Actions is](#1-what-github-actions-is)
2. [Workflow, job, step](#2-workflow-job-step)
3. [Triggers: what makes a workflow run](#3-triggers-what-makes-a-workflow-run)
4. [Runners: which machine runs it](#4-runners-which-machine-runs-it)
5. [Variables and secrets](#5-variables-and-secrets)
6. [Inputs: asking the operator a question](#6-inputs-asking-the-operator-a-question)
7. [Reading a run](#7-reading-a-run)
8. [Editing safely](#8-editing-safely)
9. [Common failures and what they look like](#9-common-failures-and-what-they-look-like)
10. [What to learn next](#10-what-to-learn-next)

---

## 1. What GitHub Actions is

GitHub Actions runs commands for you on a computer, when something happens in your
repository.

That is genuinely all it is. There is no magic:

* You write a **YAML file** and put it in the directory `.github/workflows/`.
* The file says *when* to run and *what to run*.
* GitHub notices the file, and when the "when" happens, it runs the "what".

This repository has three such files:

```
.github/workflows/deploy.yml       install or upgrade the Teleport cluster
.github/workflows/uninstall.yml    remove it
.github/workflows/lint.yml         check the other two are still valid
```

The directory name is the only thing that matters. The *filenames* are arbitrary —
`deploy.yml` could be called `banana.yml` and would behave identically. Nothing
outside `.github/workflows/` is special.

The name that appears in GitHub's user interface comes from a key inside the file.
In `.github/workflows/deploy.yml:32`:

```yaml
name: Deploy Teleport cluster
```

That string is what you will look for in the Actions tab.

---

## 2. Workflow, job, step

Three levels, always in this order.

**A workflow** is one YAML file. `deploy.yml` is a workflow.

**A job** is a unit of work that runs on one machine. A workflow can have many
jobs; they run in parallel by default, on separate machines.

**A step** is one thing inside a job: either a shell command (`run:`) or a
pre-packaged action someone else wrote (`uses:`). Steps in a job run **in order**,
on the same machine, sharing the same directory.

`deploy.yml` has exactly **one job** with eighteen steps. That was a deliberate
teaching decision: separate jobs would mean explaining `needs:`, job outputs, and
the fact that each job starts with a fresh empty directory — real concepts, but not
on page one. One job with well-named steps reads top to bottom like a shell script.

The structure, from `.github/workflows/deploy.yml:77`, `:86` and `:140`:

```yaml
jobs:
```

```yaml
  deploy:
```

```yaml
    steps:
```

`deploy` is the job's internal name (you pick it; it shows up in the run's
sidebar), and everything under `steps:` is the list of steps.

Here is a complete, minimal step — `.github/workflows/deploy.yml:155-156`:

```yaml
      - name: Check out this repository onto the runner
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
```

Three things to notice:

* **`- name:`** is a label you choose. It is what you see and click on in the run.
  Write it as a plain-English sentence; you will be reading it under pressure one
  day.
* **`uses:`** means "run somebody else's packaged step". `actions/checkout` is
  GitHub's official action that does a `git clone` of your repository onto the
  machine. **Without this step the machine has no copy of your files** — a job
  starts in an empty directory. This surprises everyone once.
* **`@3d3c42e5...`** is a git commit SHA, not a version tag. More on that in
  section 4.

The other kind of step runs shell commands. `.github/workflows/deploy.yml:1089-1091`:

```yaml
      - name: Collect diagnostics because something failed
        if: failure()
        run: |
```

Everything indented under `run: |` is a shell script. The `|` is YAML for "the
following indented block is one multi-line string".

**This project puts all of its logic in `run:` blocks rather than in separate
`.sh` files, on purpose.** You should be able to read `deploy.yml` from top to
bottom and see everything that happens without opening another file. Nothing is
lost by doing it this way: `actionlint`, run by `lint.yml`, feeds every inline
`run:` block through `shellcheck`, so the shell in these workflows gets exactly
the same scrutiny a standalone script would.

---

## 3. Triggers: what makes a workflow run

The `on:` key. This is the "when".

### `workflow_dispatch` — a button

`.github/workflows/deploy.yml:46-52`:

```yaml
on:
  workflow_dispatch:
    inputs:
      dry_run:
        description: 'Render and validate only -- do not install'
        type: boolean
        default: false
```

`workflow_dispatch` means **"only when a human presses the button"**. It puts a
*Run workflow* button in the Actions tab. Nothing else can start this workflow.

Both `deploy.yml` and `uninstall.yml` are dispatch-only, and this is a deliberate
choice for a novice operator: you should press the button on purpose and watch what
happens, rather than have a `git push` quietly change a live cluster while you are
still finding your feet.

### `pull_request` and `push` — automatic

`.github/workflows/lint.yml:36-43`:

```yaml
on:
  pull_request:
  push:
    branches:
      - main
      - master
      - mvp-cluster-only
  workflow_dispatch:
```

Three triggers on one workflow, and this is the file where you can see what each
one does:

* **`pull_request:`** — runs every time someone pushes to a branch that has an open
  pull request, and the result appears as a check on the pull request page. This is
  "CI as a gate": you see a red ✗ *before* merging rather than after.
* **`push:` with `branches:`** — runs again after the merge, so those branches are
  always known-good.
* **`workflow_dispatch:`** — you can also run it by hand, like the other two.

### Adding a `push:` trigger to deploy, later

You may eventually want the cluster to update itself when you merge a change.
That is a reasonable thing to want, and this is what to understand first:

**A `push:` trigger makes merging into that branch equivalent to running a
deploy.** So the question "who may deploy?" becomes "who may merge?". Before
adding one:

1. Turn on **branch protection** for the branch (Settings → Branches), requiring a
   pull request and requiring the `lint.yml` checks to pass. Otherwise a direct
   push to `main` deploys with no review at all.
2. Consider a GitHub **Environment** with required reviewers, so a deploy pauses
   until a named human approves it in the UI.
3. Keep `concurrency:` as it is (section 7), so two merges in quick succession
   queue rather than fight.

---

## 4. Runners: which machine runs it

A **runner** is the computer that executes a job. `runs-on:` chooses which kind.

### GitHub-hosted

`.github/workflows/lint.yml:66`:

```yaml
    runs-on: ubuntu-latest
```

GitHub creates a fresh virtual machine in its own cloud, runs the job, and destroys
the machine. It comes preloaded with common software. You pay nothing on public
repositories, and there is nothing to maintain.

### Self-hosted

`.github/workflows/deploy.yml:93-95`:

```yaml
    # This job MUST run on a self-hosted runner: GitHub's own runners live in
    # GitHub's cloud and cannot reach your Kubernetes API server.
    runs-on: [self-hosted, linux, "${{ vars.RUNNER_LABEL }}"]
```

A machine **you** own, running a small agent that polls GitHub for work.
`runner/install-runner.sh` sets one up.

The runner connects *outward* to GitHub and asks for jobs. **Nothing ever connects
inward to it**, so it needs no open ports and no public IP. Operators frequently
assume otherwise.

**Labels.** A runner carries labels, and a *list* in `runs-on:` means "a runner
carrying **all** of these". `self-hosted` and `linux` are added automatically by
GitHub; the third comes from the `RUNNER_LABEL` repository variable, so you can
name your runner whatever you like without editing the workflow. Whatever you put
in `RUNNER_LABEL` must be one of the labels you passed to `install-runner.sh`
via `--labels`, or the job will queue forever looking for a runner that does not
exist.

### Why deploy needs self-hosted and lint does not

`deploy.yml` has to talk to your Kubernetes API server. GitHub's runners are on
the public internet and generally cannot. `lint.yml` only reads files, so a
disposable machine is perfect.

**That difference is a security boundary, not a convenience.** `lint.yml` is
triggered by `pull_request`, which means it runs the code from the pull request's
branch — including any change that pull request made to the workflow file itself.
Anyone can open a pull request. Running that on a throwaway GitHub machine is fine;
running it on *your* runner, which holds live Kubernetes credentials, would hand a
stranger your cluster.

So this project has an absolute rule: **no workflow that runs on the self-hosted
runner may be triggered by a pull request.** `lint.yml` checks it mechanically on
every pull request — see the step at `.github/workflows/lint.yml:308`.

### Why actions are pinned to commit SHAs

Look again at `.github/workflows/deploy.yml:156`:

```yaml
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
```

Most examples on the internet write `actions/checkout@v7`. A tag like `v7` is a
*movable pointer*: whoever owns that repository can make it point at different code
tomorrow. A commit SHA cannot be moved.

Since `uses:` runs someone else's code **on your runner, which has your cluster
credentials**, pinning to a SHA means the code you reviewed is the code that runs.
The `# v7.0.1` comment records which release the SHA corresponds to, for humans.

---

## 5. Variables and secrets

Both live in the GitHub UI under **Settings → Secrets and variables → Actions**, on
the same page, in two tabs. They are not the same thing.

|  | Variables | Secrets |
|---|---|---|
| Tab | *Variables* | *Secrets* |
| Written in YAML as | `${{ vars.NAME }}` | `${{ secrets.NAME }}` |
| Visible in run logs | **Yes** | No — masked as `***` |
| Readable back in the UI | Yes | No, only replaceable |
| Right for | configuration | passwords, tokens, keys |

**This project uses variables only. It has zero secrets.**

`.github/workflows/deploy.yml:120-129`:

```yaml
    env:
      TELEPORT_VERSION: ${{ vars.TELEPORT_VERSION }}
      TELEPORT_CLUSTER_NAME: ${{ vars.TELEPORT_CLUSTER_NAME }}
      K8S_NAMESPACE: ${{ vars.K8S_NAMESPACE }}
      TLS_SECRET_NAME: ${{ vars.TLS_SECRET_NAME }}
      LICENSE_SECRET_NAME: ${{ vars.LICENSE_SECRET_NAME }}
      SERVICE_TYPE: ${{ vars.SERVICE_TYPE || 'LoadBalancer' }}
      PUBLIC_ADDR: ${{ vars.PUBLIC_ADDR }}
      STORAGE_CLASS: ${{ vars.STORAGE_CLASS }}
      VOLUME_SIZE: ${{ vars.VOLUME_SIZE || '10Gi' }}
```

Several things worth extracting from those ten lines.

**`${{ ... }}` is an expression.** GitHub evaluates it *before* the job runs and
substitutes the result. `vars` is one of several *contexts* available inside those
braces; `inputs`, `env` and `github` are others.

**`|| 'LoadBalancer'` supplies a default.** If the variable is unset or empty, the
right-hand side is used. That is why `SERVICE_TYPE` is optional but always has a
value by the time the shell sees it.

**`env:` copies them into environment variables, once, at the top of the job.**
Every `run:` step below can then use ordinary shell variables like
`"$K8S_NAMESPACE"`.

That last point is more than tidiness. Writing `${{ vars.X }}` *directly inside* a
`run:` block pastes the value into the script **as text** before bash ever sees it.
A value containing a quote or a semicolon could therefore change what the script
does. Passing values through `env:` avoids that completely, because bash receives
them as data rather than as source code. Get into this habit now; it matters much
more the day some value comes from an untrusted source.

### Why this project has no secrets

* Your **TLS private key** and your **Teleport licence** live in Kubernetes
  Secrets that you create by hand. `deploy.yml` checks they exist, inspects the
  *public* certificate, and never decodes the private key or the licence.
* Your **Kubernetes credentials** live only on the runner VM. The workflow's entire
  contract is *"`kubectl` is already authenticated"*.

Because variables are printed in logs, this project prints them on purpose, in the
step at `.github/workflows/deploy.yml:168`. Seeing the values you typed into the
GitHub UI arrive in the run makes the whole idea concrete — and none of them are
sensitive.

The rule is enforced by code rather than by good intentions: the guard at
`.github/workflows/lint.yml:253` fails the build if any workflow references
`secrets.*`, other than the `secrets.GITHUB_TOKEN` that GitHub creates
automatically for every run.

---

## 6. Inputs: asking the operator a question

`inputs:` under `workflow_dispatch:` become fields in the *Run workflow* dialog.

### `dry_run` — a safe way to explore

`.github/workflows/deploy.yml:46-52`:

```yaml
on:
  workflow_dispatch:
    inputs:
      dry_run:
        description: 'Render and validate only -- do not install'
        type: boolean
        default: false
```

`description:` is the label you see next to the checkbox. `type: boolean` makes it
a checkbox rather than a text box.

Inside the workflow you read it as `inputs.dry_run`, and the usual way to use a
boolean input is on `if:`. `.github/workflows/deploy.yml:738-739`:

```yaml
      - name: Stop here, because this was a dry run
        if: ${{ inputs.dry_run }}
```

...and its mirror image, `.github/workflows/deploy.yml:764-765`:

```yaml
      - name: Install or upgrade the Teleport Helm release
        if: ${{ !inputs.dry_run }}
```

**`if:` on a step means "only run this step when the expression is true".** The `!`
is "not". Every step that changes your cluster carries `if: ${{ !inputs.dry_run }}`,
so ticking the box turns the whole workflow into a read-only check of your setup.
Skipped steps still appear in the run, greyed out, which is more instructive than
hiding them.

Use `dry_run: true` after any change. It is completely safe and there is no reason
to be sparing with it.

### `confirm` — a deliberate speed bump

`.github/workflows/uninstall.yml:27-37`:

```yaml
on:
  workflow_dispatch:
    inputs:
      confirm:
        description: 'Type the cluster name to confirm (e.g. teleport.example.com)'
        required: true
        type: string
      delete_pvc:
        description: 'Also delete the data volume (DESTROYS all cluster state)'
        type: boolean
        default: false
```

`required: true` means GitHub will not let you start the run with the field empty.
But GitHub cannot check *what* you typed, so the workflow does — the first step,
at `.github/workflows/uninstall.yml:87`:

```bash
          if [[ "${CONFIRM}" != "${TELEPORT_CLUSTER_NAME}" ]]; then
```

Typing the cluster name is friction on purpose: it forces you to look at *which*
cluster this repository is configured for before you destroy it. It is the only
thing standing between a mis-click and a dead cluster. The heavier-weight option,
which this MVP mentions but does not implement, is a GitHub Environment with
required reviewers (section 10).

---

## 7. Reading a run

### Finding a run

**Actions** tab → pick the workflow in the left sidebar → pick the run.

Each run shows its jobs. Click the job to see its steps. Click a step to expand
its log. Steps are colour-coded: green ✓ succeeded, red ✗ failed, grey ⊘ skipped
(usually because of an `if:`), yellow ● still running.

### The single most useful habit

**Find the *first* red step and read it. Ignore everything after it.** Later
failures are almost always consequences of the first one. Scrolling to the bottom
and reading the last error is the most common way to waste twenty minutes.

### Annotations

Lines in a log beginning with `::error` or `::warning` are instructions to GitHub
rather than ordinary output. GitHub lifts them out and shows them at the top of the
run. `.github/workflows/deploy.yml:388` is an example:

```bash
            echo "::error title=Namespace does not exist::'${K8S_NAMESPACE}' not found -- see docs/setup.md steps 1-3"
```

Every failure in this project's workflows emits one, and every one of them names
what to fix and where to read about it.

### Step summaries

`$GITHUB_STEP_SUMMARY` is a file the runner provides. Anything a step appends to it
is rendered as Markdown on the run's summary page, so the important results are on
the front page instead of buried in a log you have to expand.
`.github/workflows/deploy.yml:196`:

```bash
          } >> "$GITHUB_STEP_SUMMARY"
```

After a successful deploy, the summary is where you will find **the DNS record to
create** and **the command to create your first user**. Look there first.

### Passing a value from one step to the next

Each `run:` block is a separate shell, so a normal shell variable does not survive
into the next step. `$GITHUB_ENV` is how you carry one across.
`.github/workflows/deploy.yml:516`:

```bash
          echo "CERT_NOT_AFTER=${not_after}" >> "$GITHUB_ENV"
```

Appending `NAME=value` to that file makes `NAME` an environment variable in every
**later** step of the job (not in the current one). That is how the certificate's
expiry date, discovered in step 8, reaches the summary written in step 18. There is
a sibling, `$GITHUB_PATH`, which does the same thing for `PATH` —
`.github/workflows/lint.yml:103`:

```bash
          echo "${HOME}/bin" >> "$GITHUB_PATH"
```

### `if: failure()` and artifacts

Normally, when a step fails, every later step is skipped. Sometimes you want the
opposite. `.github/workflows/deploy.yml:1089-1090`:

```yaml
      - name: Collect diagnostics because something failed
        if: failure()
```

`failure()` is true only when an earlier step in the job has failed, so this step
runs *only* on a bad day. Its companions are `always()` (used at
`.github/workflows/uninstall.yml:246`, because "what state is my cluster in now?"
is a question you have either way) and `success()`, the implicit default.

An **artifact** is a file attached to the run and downloadable from a box at the
bottom of the run's summary page. `.github/workflows/deploy.yml:1168-1180`:

```yaml
      - name: Attach the diagnostics to this run as a downloadable file
        if: failure()
        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1
        with:
          name: teleport-deploy-diagnostics
          path: |
            diagnostics.txt
            rendered-values.yaml
            rendered-manifests.yaml
          # Do not fail the upload just because an earlier step never got far
          # enough to create one of those files.
          if-no-files-found: ignore
          retention-days: 14
```

`with:` is how you pass parameters to an action — each action documents its own.
So when a deploy fails, you can download one text file containing the pod states,
the events, the logs and the Helm history, instead of scrolling.

### Runs that wait

If a run sits in *Queued* forever, it is waiting for a machine. For a
`self-hosted` job that means no runner with all the required labels is online —
check **Settings → Actions → Runners** and check `RUNNER_LABEL`.

If it says something about concurrency, another run of the same group holds the
lock. `.github/workflows/deploy.yml:63-65`:

```yaml
concurrency:
  group: teleport-mvp
  cancel-in-progress: false
```

Runs sharing a `group` are serialised. `cancel-in-progress: false` is the important
half: this project would rather queue behind a running deploy than kill one halfway
through a Helm install and leave the release needing manual repair.
`uninstall.yml` uses the same group name, so a deploy and an uninstall can never
overlap either.

### One more top-level key

`.github/workflows/deploy.yml:74-75`:

```yaml
permissions:
  contents: read
```

GitHub mints a short-lived token for every run. `permissions:` narrows what it may
do. This workflow only needs to read its own repository's files, so that is all it
asks for. Narrowing costs nothing and is a good habit.

---

## 8. Editing safely

There are two quite different kinds of change, and the difference matters.

### Changing a variable — no commit, no review

**Settings → Secrets and variables → Actions → Variables**, edit, save, re-run the
workflow. Nothing is committed; no pull request; `lint.yml` does not run, because
nothing in the repository changed.

Use this for `TELEPORT_VERSION`, `SERVICE_TYPE`, `VOLUME_SIZE`, `STORAGE_CLASS`.
It is the intended way to reconfigure this project. Anything a variable can
express, express with a variable.

### Changing a workflow or the values files — commit, and lint runs

1. Make a branch and commit your change.
2. Open a pull request. `lint.yml` runs automatically on GitHub's runner and
   comments on the pull request page. It will tell you about invalid YAML, a bad
   `${{ }}` expression, a shell bug in an inline `run:` block, a values file that
   no longer renders a valid chart, and either of this project's two security
   rules being broken.
3. Fix anything red, merge.
4. **Run `deploy.yml` with `dry_run` ticked** before running it for real.

That last step is the habit to build. A dry run exercises every check without
changing anything.

### Running the checks locally first

You do not have to push to find out. From the repository root, with the same tools
`lint.yml` uses:

```bash
          actionlint -color .github/workflows/*.yml
```

```bash
          yamllint --strict --config-file .yamllint.yml .github/workflows/ helm/
```

```bash
          shellcheck runner/install-runner.sh
```

Those three lines are quoted exactly as they appear in the workflow —
`.github/workflows/lint.yml:131`, `:144` and `:156` — indentation included, which
is why they look over-indented here. Paste them into a shell without it.

### If you edit one Helm values file, edit both

`helm/values.yaml` and `helm/values.nodeport.yaml` are near-copies: the second
differs only in hardcoding `NodePort` and adding `publicAddr`. Two readable files
were chosen over one file full of conditionals, and keeping them in step is the
price. `lint.yml` renders **both**, so a change that breaks one will be caught —
but a change you simply forgot to apply to the other will not.

---

## 9. Common failures and what they look like

Each of these is a check that exists because the underlying failure is otherwise
hard to diagnose. The workflow's message tells you what to fix; this table tells
you why it is phrased that way.

### A required variable is not set

```
::error title=Missing repository variables::TELEPORT_CLUSTER_NAME -- see docs/setup.md step 6
```

From `.github/workflows/deploy.yml:227`. This is caught in the *third* step, before
anything touches the cluster, because the templating tool replaces an unset
variable with an empty string rather than complaining — so the real symptom would
otherwise be a baffling Helm error several minutes later.

**Fix:** Settings → Secrets and variables → Actions → **Variables**, and check the
spelling. Also check the tab: values added under *Secrets* will not appear as
`vars`.

### The runner's Kubernetes credentials are not working

```
::error title=Cannot reach the Kubernetes cluster::The runner's credentials are not working -- see docs/setup.md step 5
```

From `.github/workflows/deploy.yml:318`. **This is the most likely thing to fail on
your first run**, and it is the reason that check exists as its own step: without
it, broken credentials surface ten minutes later as an unexplained Helm timeout.

**Fix:** on the runner VM, `sudo -u github-runner kubectl get ns`. The workflow does
not manage credentials at all — see [`setup.md`](setup.md) step 5. If your
credentials are short-lived (Teleport MWI, `tbot`, cloud SSO), the usual cause is
that they expired and whatever renews them is not running.

A near neighbour, from `.github/workflows/deploy.yml:354`, is when the credentials
work but RBAC is too narrow:

```
::error title=Insufficient Kubernetes permissions::Missing: create deployments -- see docs/setup.md step 5
```

The log above it prints a `yes`/`NO` table of every permission that was checked.

### The namespace does not exist

```
::error title=Namespace does not exist::'teleport' not found -- see docs/setup.md steps 1-3
```

From `.github/workflows/deploy.yml:388`. The workflow deliberately does **not**
create the namespace, because it is where your two hand-made Secrets live. A
silently-created empty namespace would let the run get two steps further and then
fail on a missing Secret — a worse error, further away from its cause.

**Fix:** `kubectl create namespace teleport`, then create both Secrets
([`setup.md`](setup.md) steps 1–3). Or fix `K8S_NAMESPACE` if you meant a different
one.

### The licence Secret has the wrong key name

```
::error title=Licence secret has the wrong key name::'teleport-license' needs a 'license.pem' key; it has: license
```

From `.github/workflows/deploy.yml:560`. A very common mistake with a genuinely
opaque native failure mode: the chart mounts the Secret at
`/var/lib/license/license.pem`, so a differently-named key produces a file Teleport
cannot find, and the auth pod crash-loops with a message that never mentions the
Secret.

**Fix:** recreate it with the key name given explicitly:

```bash
kubectl create secret generic teleport-license \
  --from-file=license.pem=/path/to/license.pem -n teleport
```

The workflow checks the key **name** only. It never reads the value.

### The certificate does not cover the cluster name

```
::error title=Certificate name mismatch::'teleport.example.com' is not on the certificate in 'teleport-tls'
```

From `.github/workflows/deploy.yml:479`. Teleport would start perfectly happily
with a mismatched certificate; you would find out from your users' browser
warnings, days later. So the check is done up front, against the certificate's
Subject Alternative Names and Common Name.

**Fix:** either re-issue the certificate for that name, or correct
`TELEPORT_CLUSTER_NAME` to match the certificate. The log prints every name found
on the certificate, which usually makes it obvious which of the two is wrong.

Related, from `.github/workflows/deploy.yml:491`, and checked at the same time:

```
::error title=Certificate has expired::Expired Jun  1 00:00:00 2026 GMT
```

Under 30 days remaining is a warning rather than an error. Renewing needs no
redeploy at all — see [`runbook.md`](runbook.md).

### The chart version does not exist

```
::error title=Chart version not found::teleport-cluster '18.1.11' does not exist
```

From `.github/workflows/deploy.yml:597`. A transposed digit in `TELEPORT_VERSION`
is caught in two seconds instead of after a failed image pull. The log lists the
ten most recent real versions.

Note that this check demands an *exact* match, because Helm treats `--version` as a
semver range and would otherwise happily install something else for `18.11`.

### `PUBLIC_ADDR` is required for NodePort

```
::error title=PUBLIC_ADDR is required for NodePort::Set PUBLIC_ADDR to teleport.example.com:<nodePort>
```

From `.github/workflows/deploy.yml:255`. With `SERVICE_TYPE=NodePort`, Kubernetes
exposes Teleport on a random port between 30000 and 32767, but the chart still
advertises port 443 to clients — so without `PUBLIC_ADDR` every client is told to
connect somewhere nothing is listening. The full explanation is at the top of
[`../helm/values.nodeport.yaml`](../helm/values.nodeport.yaml).

**Fix:** set `PUBLIC_ADDR` to `<cluster-name>:<node-port>`. You do not know the
port until you have deployed once, so use a placeholder, deploy, read the real port
from the run summary, set it properly and re-run.

### The Service never gets an address

```
::error title=LoadBalancer never got an address::No load balancer controller in this cluster. Use SERVICE_TYPE=NodePort, or install MetalLB. See docs/runbook.md.
```

From `.github/workflows/deploy.yml:870`, after three minutes of polling. The Service
sits at `EXTERNAL-IP <pending>` because nothing in the cluster is watching for
`LoadBalancer` Services — normal on kubeadm, k3s without servicelb, and home labs.

**Fix:** either `SERVICE_TYPE=NodePort` (plus `PUBLIC_ADDR`), or install MetalLB.
Teleport itself installed correctly in this case; only its external address is
missing. This is exactly the failure a bare timeout would have made a mystery,
which is why it gets its own message naming both fixes.

### `UPGRADE FAILED: another operation is in progress`

Not a check — a real Helm error, from a previous run that was interrupted. See
[`runbook.md`](runbook.md) for the `helm history` / `helm rollback` recovery. The
`concurrency` block quoted in section 7 exists to make this rare.

### The job stays Queued forever

No runner is online with all the labels in `runs-on:`. Check **Settings → Actions →
Runners** for an *Idle* runner, and check that `RUNNER_LABEL` matches one of the
labels you gave `install-runner.sh`.

---

## 10. What to learn next

You now know enough to operate and to make small changes to this repository. Here
is the map of what you skipped, and — more usefully — when you would actually want
each thing.

**`needs:` and multiple jobs.** `needs: build` makes one job wait for another, and
lets independent jobs run in parallel. Want it when you have genuinely independent
work (testing three configurations at once), or when one part must run on a
different kind of runner from another. Remember that each job gets a fresh machine
and a fresh empty directory, so anything shared between them has to be passed
explicitly as a job output or an artifact.

**Matrices.** `strategy: matrix:` runs the same job many times with different
values — "test against Teleport 17 and 18". Want it when you are genuinely
supporting several versions.

**Environments.** A named environment (Settings → Environments) can require
approval from specific people before a job that targets it will run. **This is the
first thing to add if more than one or two people can press the deploy button** —
`uninstall.yml`'s typed confirmation is a speed bump, whereas an environment is a
real gate. It can also hold environment-scoped variables, which is how you would
grow into staging and production clusters.

**Reusable workflows and composite actions.** Ways to share steps between
workflows so you write them once. Want them when you notice yourself copying the
same eight steps into a third file. This project deliberately does not use them:
with three workflows, the duplication is cheaper than the indirection, and a novice
reading `deploy.yml` would have to open another file to see what actually happens.

**OIDC.** Workflows can exchange a GitHub-issued identity token for short-lived
cloud credentials, so there is no stored key anywhere. This is the correct answer
to "how do I give a workflow access to AWS or GCP" and it is worth knowing that the
answer is *not* "put a key in a secret". This project sidesteps the question
differently: the runner already has ambient Kubernetes credentials, ideally via
Teleport Machine & Workload Identity, so the pipeline never handles one at all.

**Caching.** `actions/cache` speeds up repeated downloads. Want it for builds with
big dependency trees, not for this — the two downloads here take seconds.

**Where to read.** <https://docs.github.com/actions> is genuinely good, and its
workflow-syntax reference (`Reference → Workflow syntax`) is the page you will keep
open. The three files in this repository's `.github/workflows/` directory are a
reasonable second reference, precisely because they are over-commented.
