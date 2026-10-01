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
### Configuration – Teleport cluster
Create a folder under `configs` with the following:
- `gh_vars.env` with required variables:
	- `DEPLOY_ENV` is required for running on push, since no inputs are available to get the value from. Should match the config folder name. 
	- `K8S_NAMESPACE` to deploy teleport cluster into. Should match the pre-configured NS with secrets;
	- `TELEPORT_VERSION` to specify the desired cluster version;
- `/helm/teleport-cluster-values.yaml` – Helm values file. [Chart reference.](https://goteleport.com/docs/reference/helm-reference/teleport-cluster/) Note: if you wish to use MWI pipeline, values need to containg the following label, which will be used to configure Teleport K8S cluster access:
	```yaml
	labels:
	  gha_tbot_managed: true
	```
- Create a tbot.yaml file in the repo root with a tbot config. `tbot` [config reference](https://goteleport.com/docs/reference/machine-workload-identity/configuration/).
Lint runs on push, deploy is currently limited to manual runs due to self-hosted runner usage. 

#### MWI configuration options
If you wish to use this pipeline to further configure your newly deployed Teleport cluster, you'll need to configure `tbot` for access. This can be done either by ticking a `Configure tbot for this GHA pipeline from the new cluster` checkbox, or by configuring your own role and bot user and supplying the `tbot.yaml` config in the `configs/[env name]/teleport/mwi` folder. 

If you proceed with a pipeline-configurated tbot, Deploy Cluster workflow will:
- Create a Role `gha-ci-bot` for bot with `create`, `list`, `read` permissions on `role` resources and `create`, `update`, `list`,  `read` permissions on `auth_connector` resources;
- Create a GitHub-type Join Token `gha-bot-token` for the repository;
- Create a bot user `gha-bot` with the Role and Join Token.
SSO and RBAC pipelines will automatically check if the user-provided `tbot.yaml` config is present and use it, if not – the config is generated for each run based on automatically created role and bot user. 
> Note: Default bot role specifically omits `update` on the `role` resource to prevent potential privilege escalation through modifying own role. This means the pipeline by default can not make changes to the Role resources, only create new ones. 
### Configuring Teleport SSO connectors
To use this workflow, add at least one Teleport SSO connector configuration file to `configs/[env name]/teleport/sso`. This workflow requiures MWI to be configured. 
### Configuring Teleport RBAC
To use this workflow, add at least one Teleport RBAC yaml configuration file to `configs/[env name]/teleport/rbac`. This workflow requiures MWI to be configured.