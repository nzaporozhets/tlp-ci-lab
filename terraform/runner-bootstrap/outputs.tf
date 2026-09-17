output "runner_instance_id" {
  description = "Instance ID of the self-hosted runner. Connect with: aws ssm start-session --target <id>"
  value       = aws_instance.runner.id
}

output "runner_role_arn" {
  description = "ARN of the runner's instance role. Everything the workflows do in AWS is done as this role."
  value       = aws_iam_role.runner.arn
}

output "runner_role_name" {
  description = "Name of the runner's instance role."
  value       = aws_iam_role.runner.name
}

output "runner_security_group_id" {
  description = "Runner security group (egress only)."
  value       = aws_security_group.runner.id
}

output "tool_versions" {
  description = "Tool versions installed on the runner, parsed from tool-versions.env. .github/actions/setup-tools asserts these at the start of every run."
  value       = local.tool_versions
}

output "ssm_session_command" {
  description = "Command to open an administrative shell on the runner."
  value       = "aws ssm start-session --region ${var.aws_region} --target ${aws_instance.runner.id}"
}

output "next_steps" {
  description = "Repository variables and secrets to configure before the first deploy."
  value       = <<-EOT
    Runner created: ${aws_instance.runner.id} (role ${aws_iam_role.runner.arn})

    1. Confirm the runner shows as Idle under
       https://github.com/${var.github_owner}/${var.github_repo}/settings/actions/runners
       with labels: self-hosted, linux, x64, ${var.runner_label}
       If not, open a shell and look at the logs:
         ${"aws ssm start-session --region ${var.aws_region} --target ${aws_instance.runner.id}"}
         sudo journalctl -u github-runner -n 200 --no-pager
         sudo cat /var/log/cloud-init-output.log

    2. Create the GitHub Environment `teleport-ci`
       (Settings -> Environments), restricted to the `main` branch, with required
       reviewers on destroy. Add these secrets to it:
         KUBECONFIG                    base64 of a kubeconfig for the CI ServiceAccount
         TELEPORT_ENTERPRISE_LICENSE   contents of license.pem

    3. Set these repository variables (Settings -> Actions -> Variables):
         TELEPORT_VERSION          ${var.teleport_version}
         TELEPORT_CLUSTER_NAME     <the public hostname, IMMUTABLE once deployed>
         ACME_EMAIL                <contact address>
         ACME_USE_STAGING          true   (flip to false once the pipeline is green)
         AWS_REGION                ${var.aws_region}
         ROUTE53_ZONE_ID           ${var.route53_zone_id}
         TF_STATE_BUCKET           ${var.tf_state_bucket}
         EC2_AGENT_INSTANCE_TYPE   t3.micro
         EC2_AGENT_SUBNET_ID       <subnet with outbound internet>
         EC2_AGENT_VPC_ID          ${var.vpc_id}
         K8S_NAMESPACE_CLUSTER     teleport
         K8S_NAMESPACE_AGENT       teleport-agent
         KUBE_CLUSTER_NAME         <display name in Teleport>
         RUNNER_LABEL              ${var.runner_label}

    4. Enable branch protection with a required review on `main`. deploy.yml
       triggers on push to main and runs on this runner, so branch protection is
       the control that keeps unreviewed code off it (SPEC.md §10.1).

    5. Store terraform.tfstate for this module somewhere durable and private. It
       is NOT in the CI state bucket, and the runner's role cannot recreate it.
  EOT
}
