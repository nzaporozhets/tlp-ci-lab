output "instance_id" {
  description = "Instance ID of the Teleport agent node. scripts/verify.sh asserts a Teleport SSH node with this ID has joined."
  value       = aws_instance.agent.id
}

output "private_ip" {
  description = "Private IP of the agent node (it has no public ingress)."
  value       = aws_instance.agent.private_ip
}

output "role_name" {
  description = "Name of the no-op instance role. Must match EC2_AGENT_ROLE_NAME used to render teleport/tokens/ec2-agent-token.yaml."
  value       = aws_iam_role.agent.name
}

output "role_arn" {
  description = "ARN of the no-op instance role."
  value       = aws_iam_role.agent.arn
}

output "expected_join_arn" {
  description = "The assumed-role ARN pattern the Teleport provision token must allow. Compare with spec.allow[].aws_arn in teleport/tokens/ec2-agent-token.yaml if joining fails."
  value       = "arn:aws:sts::${data.aws_caller_identity.current.account_id}:assumed-role/${aws_iam_role.agent.name}/i-*"
}

output "security_group_id" {
  description = "Agent security group (egress only)."
  value       = aws_security_group.agent.id
}

output "sentinel_path" {
  description = "Path of the user-data completion sentinel on the instance. Present and containing 'ok' means user-data finished successfully."
  value       = local.sentinel_path
}

data "aws_caller_identity" "current" {}
