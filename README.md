# Deploy a Teleport cluster with GitHub Actions

## Prerequisites
- Pre-existing k8s cluster, configured for tbot access
- K8s namespace for Teleport cluster deployment, pre-configured with following:
	- TLS cert secret `teleport-tls`;
	- Teleport license secret `teleport-license`;
	-  If using PG backend:
		- `pgclientcrt`, `pgclientkey` `pgcacrt` secrets with respective certs and keys for PG auth;
- VM for GitHub runner which is able to reach your K8s cluster (and governing Teleport cluster for `tbot`)
## Assumptions
- K8s cluster and Postgres DB are pre-created and managed separately;
- Pipeline is not managing any infra side resources to stay platform-agnostic and, in our case,  eliminate the need to provide AWS access:
	- Certificate is pre-created and provided 
	- kubeconfig/k8s access is provided to runner
- tbot k8s roles are not managed by this pipeline
- Chicken and egg: first run uses `tbot` from a _different_ Teleport cluster to get access to a kubeconfig.
## Usage
### Runner prep
#### Get a registration token 
In this repository on GitHub:

**Settings → Actions → Runners → New self-hosted runner**

GitHub shows you a set of commands. You only need the token from the `./config.sh --token ...` line. It **expires in about an hour** and can only register a runner — it is not a long-lived credential, and it is not a GitHub secret.
#### Run the installer
Copy [`runner/install-runner.sh`](https://github.com/nzaporozhets/tlp-ci-lab/blob/nz-multienv/runner/install-runner.sh) to the VM and run it as root:

```shell
sudo ./install-runner.sh \
  --url    https://github.com/<owner>/<repo> \
  --token  <registration-token> \
  --labels self-hosted,linux,teleport
```
###g Configuration
Create a folder under `configs` with the following:
- `gh_vars.env` with required variables:
	- `DEPLOY_ENV` is required for running on push, since no inputs are available to get the value from. Should match the config folder name. 
	- `K8S_NAMESPACE` to deploy teleport cluster into. Should match the pre-configured NS with secrets;
	- `TELEPORT_VERSION` to specify the desired cluster version;
- `teleport-cluster-values.yaml` – Helm values file. [Chart reference.](https://goteleport.com/docs/reference/helm-reference/teleport-cluster/)
Create a tbot.yaml file in the repo root with a tbot config. `tbot` [config reference](https://goteleport.com/docs/reference/machine-workload-identity/configuration/).
Lint runs on push, deploy is currently limited to manual runs due to self-hosted runner usage. 