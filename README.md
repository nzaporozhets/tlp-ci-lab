# Deploy a Teleport cluster with GitHub Actions

## Overview
## Available workflows
| Workflow name | Triggers            | Inputs                                                                                                                                                                                                                     | Purpose                                                                                                                                        |
|---------------|---------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------|
| deploy        | Manual              | `dry_run` Skips the cluster installation and optional tbot config;<br>`deploy_env` Name of the environment to deploy. Should match the folder name in `configs`;<br>`mwi_enabled` Whether to generate default tbot config. | Deploys a Teleport cluster into target k8s cluster;<br>Optionally configures MWI for the created cluster to be used by RBAC and SSO pipelines. |
| teleport-rbac | Manual, <br>on push | `dry_run` Stops before applying; still generates the list of roles to be applied;<br>`deploy_env` Name of the environment to deploy. Should match the folder name in `configs`.                                            | Applies RBAC configs (roles, ACLs) to a Teleport cluster.                                                                                      |
| teleport-sso  | Manual, <br>on push | `dry_run` Stops before applying the connector config;<br>`deploy_env` Name of the environment to deploy. Should match the folder name in `configs`.                                                                        | Applies SSO connector config to a Teleport cluster.                                                                                            |


## Prerequisites
- Pre-existing k8s cluster, configured for tbot access
- K8s namespace for Teleport cluster deployment, pre-configured with following:
	- TLS cert secret `teleport-tls`;
	- Teleport license secret `teleport-license`;
	-  If using PG backend:
		- `pgclientcrt`, `pgclientkey` `pgcacrt` secrets with respective certs and keys for PG auth;
- If using GitHub runners: Governing Teleport cluster needs to be reachable for `tbot` in the pipeline;
- Optional self-hosted VM for GitHub runner which is able to reach your K8s cluster (and governing Teleport cluster for `tbot`).
## Assumptions
- K8s cluster and Postgres DB are pre-created and managed separately;
- Pipeline is not managing any infra side resources to stay platform-agnostic and, in our case,  eliminate the need to provide AWS access:
	- Certificate is pre-created and provided 
	- kubeconfig/k8s access is provided to runner
- `tbot` k8s roles are not managed by this pipeline
- Secrets are not managed by the pipeline (see prepeqs)
- Chicken and egg: first run uses `tbot` from a _different_ Teleport cluster to get access to a kubeconfig.
## Usage
### Configuration – Teleport cluster
Create a folder under `configs` with the following:
- `gh_vars.env` with required variables:
	- `K8S_NAMESPACE` to deploy teleport cluster into. Should match the pre-configured NS with secrets;
	- `TELEPORT_VERSION` to specify the desired cluster version for the deployment (or RBAC/SSO pipelines);
	- `PARENT_TELEPORT_VERSION` is required to use GitHub runners – this specifies a version of the governing Teleport cluster.
	The file shouldn't have inline comments or quotes, because it's ingested into `$GITHUB_ENV`;
- `/helm/teleport-cluster-values.yaml` – Helm values file. [Chart reference.](https://goteleport.com/docs/reference/helm-reference/teleport-cluster/) 
- Create a tbot.yaml file in the repo root with a tbot config. `tbot` [config reference](https://goteleport.com/docs/reference/machine-workload-identity/configuration/). This config should target your governing Teleport cluster. Config for the clusters you deploy with the pipeline can be provided through `tbot.yaml` in `configs/[env name]/teleport/mwi` folder(s). Example is provided in the [`templates`](templates/) folder. 
- For your tbot config, it's recommended to limit your token based on [available `allow` rules](https://goteleport.com/docs/reference/deployment/join-methods/#github-actions-github), default is limited to repository only. This would allow other workflows and any branches to use MWI;
- RBAC and SSO pipelines are configured to run on push into respective directories or to be started manually for a specified env.

By default the pipeline is configured to run on a self-hosted runner for environments that don't have open inbound 443 on Teleport proxies. If you wish to change that, change workflow files `runs-on` property to `ubuntu-latest` (tested and confirmed working, other images might need dependencies installation steps).

Dependencies:
- `kubectl`
- `helm`
- `jq`
- `yq`
- `openssl`
- `envsubst`
- `curl`
- `base64`
- `tbot`,`tctl`, `tsh` - provided by the `teleport` package, installed by the pipeline for GitHub runners.

#### MWI configuration options
If you wish to use this pipeline to further configure your newly deployed Teleport cluster, you'll need to configure `tbot` for access. This can be achieved in two waysL:
- Tick a `Configure tbot for this GHA pipeline from the new cluster` checkbox;
- Configure your own role and bot user and supply the `tbot.yaml` config in the `configs/[env name]/teleport/mwi` folder. Example is provided in the [`templates`](templates/) folder. 

If you proceed with a pipeline-configured tbot, Deploy Cluster workflow will:
- Create a Role `gha-ci-bot` for bot with `create`, `list`, `read` permissions on `role` resources and `create`, `update`, `list`,  `read` permissions on `auth_connector` resources;
- Create a GitHub-type Join Token `gha-bot-token` for the repository;
- Create a bot user `gha-bot` with the Role and Join Token.
SSO and RBAC pipelines will automatically check if the user-provided `tbot.yaml` config is present and use it, if not – the config is generated for each run based on automatically created role and bot user. 
> Note: Default bot role specifically omits `update` on the `role` resource to prevent potential privilege escalation through modifying own role. This means the pipeline by default can not make changes to the Role resources, only create new ones. 
### Configuring Teleport SSO connectors
>This workflow requires MWI to be configured. 

To use this workflow, add at least one Teleport SSO connector configuration file to `configs/[env name]/teleport/sso`. Run on `push` is enabled for main branch for this directory. This workflow doesn't depend on the cluster deployment workflow, so you can control any Teleport clusters if you supply a suitable MWI (cluster config is still required to obtain Proxy URL).

The pipeline does not handle deletion of resources.
### Configuring Teleport RBAC
>This workflow requires MWI to be configured. 

To use this workflow, add at least one Teleport RBAC yaml configuration file to `configs/[env name]/teleport/rbac`. Run on `push` is enabled for main branch for this directory. This workflow doesn't depend on the cluster deployment workflow, so you can control any Teleport clusters if you supply a suitable MWI (cluster config is still required to obtain Proxy URL).

Default bot role specifically omits `update` on the `role` resource to prevent potential privilege escalation through modifying own role. This means the pipeline by default can not make changes to the Role resources, only create new ones. Changes to existing roles are skipped, the run still succeeds.

If you choose to allow the update action, pipeline has a step to verify it's not trying to update the roles listed as the active bot's roles, but **this doesn't protect from creating a different role and switching to the user-supplied MWI config using it** (however, lack of `update` doesn't protect from this either).

The pipeline does not handle deletion of resources.
### [Optional] Self-hosted runner – prep
#### Get a registration token 
In this repository on GitHub:

**Settings → Actions → Runners → New self-hosted runner**

GitHub shows you a set of commands. You only need the token from the `./config.sh --token ...` line. It **expires in about an hour** and can only register a runner — it is not a long-lived credential, and it is not a GitHub secret.
#### Run the installer
Copy [`runner/install-runner.sh`](runner/install-runner.sh) to the VM and run it as root:

```shell
sudo ./install-runner.sh \
  --url    https://github.com/<owner>/<repo> \
  --token  <registration-token> \
  --labels self-hosted,linux,teleport-deploy
```
Install the `teleport` package. The version should be compatible with the governing cluster and the cluster you're planning to install. Refer to [Teleport component compatibility guidelines](https://goteleport.com/docs/upgrading/overview/#component-compatibility).