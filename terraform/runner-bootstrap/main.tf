# One-time bootstrap of the self-hosted GitHub Actions runner (SPEC.md §7).
#
# Apply this ONCE, by hand, from the operator's machine. It is not applied by any
# workflow: the runner's own IAM role deliberately cannot create IAM roles outside
# ${var.agent_iam_path}, so it could not re-create itself even if asked to.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  # Single source of truth for tool versions, shared with
  # .github/actions/setup-tools/action.yml. Parsed rather than duplicated so the
  # runner and the assertion can never disagree.
  tool_versions = {
    for line in [for raw in split("\n", file("${path.module}/../../tool-versions.env")) : trimspace(raw)] :
    trimspace(element(split("=", line), 0)) => trimspace(join("=", slice(split("=", line), 1, length(split("=", line)))))
    if line != "" && !startswith(line, "#") && length(split("=", line)) > 1
  }

  state_bucket_arn = "arn:${local.partition}:s3:::${var.tf_state_bucket}"
  zone_arn         = "arn:${local.partition}:route53:::hostedzone/${trimprefix(var.route53_zone_id, "/hostedzone/")}"

  # Path without the surrounding slashes, for building IAM ARNs.
  agent_path_trimmed = trim(var.agent_iam_path, "/")
  agent_role_arn     = "arn:${local.partition}:iam::*:role/${local.agent_path_trimmed}/*"
  agent_profile_arn  = "arn:${local.partition}:iam::*:instance-profile/${local.agent_path_trimmed}/*"

  credential_parameter_arn = "arn:${local.partition}:ssm:${var.aws_region}:${local.account_id}:parameter/${trimprefix(var.credential_ssm_parameter, "/")}"
}

# ---------------------------------------------------------------------------
# IAM role for the runner. Least privilege per SPEC.md §7.2.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "runner_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "runner" {
  name               = "${var.name}-role"
  description        = "Instance role for the teleport-ci self-hosted GitHub Actions runner"
  assume_role_policy = data.aws_iam_policy_document.runner_assume_role.json
}

# SSM Session Manager: the only administrative access path to the runner.
resource "aws_iam_role_policy_attachment" "runner_ssm_core" {
  role       = aws_iam_role.runner.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "runner_identity" {
  statement {
    sid       = "IdentityCheck"
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "runner_tfstate" {
  statement {
    sid       = "ListStatePrefix"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [local.state_bucket_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${var.tf_state_prefix}*", var.tf_state_prefix]
    }
  }

  statement {
    sid    = "ReadWriteStateObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      # DeleteObject is what releases the native S3 lock file
      # (<key>.tflock) at the end of an apply.
      "s3:DeleteObject",
    ]
    resources = ["${local.state_bucket_arn}/${var.tf_state_prefix}*"]
  }

  statement {
    # Read-only, and beyond the table in SPEC.md §7.2: deploy.yml's preflight job
    # asserts the state bucket exists with versioning enabled, which is the only
    # cheap protection against unrecoverable state corruption (SPEC.md §8.1).
    sid       = "InspectStateBucket"
    effect    = "Allow"
    actions   = ["s3:GetBucketVersioning", "s3:GetBucketLocation"]
    resources = [local.state_bucket_arn]
  }
}

data "aws_iam_policy_document" "runner_dns" {
  statement {
    sid    = "ChangeProxyRecord"
    effect = "Allow"
    actions = [
      "route53:ChangeResourceRecordSets",
      "route53:ListResourceRecordSets",
      "route53:GetHostedZone",
    ]
    resources = [local.zone_arn]
  }

  statement {
    # route53:GetChange has no resource form; `aws route53 wait
    # resource-record-sets-changed` requires it.
    sid       = "PollChangeStatus"
    effect    = "Allow"
    actions   = ["route53:GetChange"]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "runner_ec2_agent" {
  statement {
    sid    = "AmiLookup"
    effect = "Allow"
    # AWS public parameters live in no account, hence the empty account field.
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["arn:${local.partition}:ssm:*::parameter/aws/service/ami-amazon-linux-latest/*"]
  }

  statement {
    sid    = "ReadRunnerRegistrationCredential"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
    ]
    resources = [local.credential_parameter_arn]
  }

  statement {
    sid       = "DecryptRunnerCredential"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.aws_region}.amazonaws.com"]
    }
  }

  statement {
    sid    = "DescribeEverythingInRegion"
    effect = "Allow"
    actions = [
      # Describe* does not support resource-level permissions.
      "ec2:Describe*",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  statement {
    sid    = "CreateAgentResources"
    effect = "Allow"
    actions = [
      "ec2:RunInstances",
      "ec2:CreateSecurityGroup",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  statement {
    # Tagging is only allowed as part of a create call. Without this condition a
    # workflow could tag somebody else's instance with
    # ManagedBy=${var.managed_by_tag_value} and then terminate it using the
    # tag-conditioned statement below.
    sid       = "TagOnCreateOnly"
    effect    = "Allow"
    actions   = ["ec2:CreateTags"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }

    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["RunInstances", "CreateSecurityGroup", "CreateVolume"]
    }
  }

  statement {
    sid    = "MutateOwnAgentResources"
    effect = "Allow"
    actions = [
      "ec2:TerminateInstances",
      "ec2:DeleteSecurityGroup",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupEgress",
      "ec2:ModifyInstanceMetadataOptions",
      "ec2:ModifyInstanceAttribute",
      "ec2:CreateTags",
      "ec2:DeleteTags",
      # Retrieves cloud-init output for the failure dumps in SPEC.md §9.5
      # without needing SSM on the agent role.
      "ec2:GetConsoleOutput",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/ManagedBy"
      values   = [var.managed_by_tag_value]
    }
  }
}

data "aws_iam_policy_document" "runner_agent_iam" {
  statement {
    # PATH-SCOPED. This is the sharpest permission the runner holds: anyone who
    # can run a workflow here can create an IAM role. Confining it to
    # ${var.agent_iam_path} plus the PassRole condition below, and withholding
    # AttachRolePolicy/PutRolePolicy, is what stops that from being privilege
    # escalation. See the explicit Deny in runner_iam_guardrail.
    sid    = "ManageAgentRoleUnderPathOnly"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:UpdateRole",
      # NOTE: iam:UpdateAssumeRolePolicy is deliberately absent (and explicitly
      # denied below) -- being able to rewrite a role's trust policy is itself an
      # escalation path. The agent role's trust policy is set once, at creation.
      "iam:TagRole",
      "iam:UntagRole",
      "iam:ListRoleTags",
      # Terraform reads these during refresh/destroy of aws_iam_role.
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:UntagInstanceProfile",
      "iam:ListInstanceProfileTags",
    ]
    resources = [local.agent_role_arn, local.agent_profile_arn]
  }

  statement {
    sid       = "PassAgentRoleToEC2Only"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [local.agent_role_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "runner_iam_guardrail" {
  statement {
    # Belt and braces for SPEC.md §7.2 / §10.2: a role the runner creates must
    # never be able to acquire permissions. An explicit Deny also survives
    # someone later attaching a broader managed policy to this runner role.
    #
    # If you ever need the agent role to carry AmazonSSMManagedInstanceCore
    # (terraform/ec2-agent var attach_ssm_policy), attach it yourself, out of
    # band -- do not relax this statement.
    sid    = "DenyGrantingPermissionsToAnyRole"
    effect = "Deny"
    actions = [
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachUserPolicy",
      "iam:PutUserPolicy",
      "iam:AttachGroupPolicy",
      "iam:PutGroupPolicy",
      "iam:CreatePolicy",
      "iam:CreatePolicyVersion",
      "iam:CreateUser",
      "iam:CreateAccessKey",
      "iam:UpdateAssumeRolePolicy",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "runner_identity" {
  name   = "identity"
  role   = aws_iam_role.runner.id
  policy = data.aws_iam_policy_document.runner_identity.json
}

resource "aws_iam_role_policy" "runner_tfstate" {
  name   = "terraform-state"
  role   = aws_iam_role.runner.id
  policy = data.aws_iam_policy_document.runner_tfstate.json
}

resource "aws_iam_role_policy" "runner_dns" {
  name   = "route53"
  role   = aws_iam_role.runner.id
  policy = data.aws_iam_policy_document.runner_dns.json
}

resource "aws_iam_role_policy" "runner_ec2_agent" {
  name   = "ec2-agent"
  role   = aws_iam_role.runner.id
  policy = data.aws_iam_policy_document.runner_ec2_agent.json
}

resource "aws_iam_role_policy" "runner_agent_iam" {
  name   = "agent-iam"
  role   = aws_iam_role.runner.id
  policy = data.aws_iam_policy_document.runner_agent_iam.json
}

resource "aws_iam_role_policy" "runner_iam_guardrail" {
  name   = "iam-guardrail"
  role   = aws_iam_role.runner.id
  policy = data.aws_iam_policy_document.runner_iam_guardrail.json
}

resource "aws_iam_instance_profile" "runner" {
  name = "${var.name}-profile"
  role = aws_iam_role.runner.name
}

# ---------------------------------------------------------------------------
# Compute.
# ---------------------------------------------------------------------------

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_security_group" "runner" {
  name_prefix = "${var.name}-"
  description = "teleport-ci GitHub Actions runner: egress only, no inbound rules. Admin access via SSM Session Manager."
  vpc_id      = var.vpc_id

  tags = { Name = var.name }

  lifecycle {
    create_before_destroy = true
  }
}

# Intentionally: no ingress rules at all, and no SSH key pair on the instance.
resource "aws_vpc_security_group_egress_rule" "runner_all_ipv4" {
  security_group_id = aws_security_group.runner.id
  description       = "Outbound to GitHub, the Kubernetes API endpoint, AWS APIs and package repositories"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_instance" "runner" {
  ami           = data.aws_ssm_parameter.al2023.value
  instance_type = var.instance_type
  subnet_id     = var.subnet_id

  vpc_security_group_ids      = [aws_security_group.runner.id]
  iam_instance_profile        = aws_iam_instance_profile.runner.name
  associate_public_ip_address = var.assign_public_ip

  monitoring = false

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    encrypted             = true
    delete_on_termination = true
  }

  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/user-data.sh.tftpl", {
    kubectl_version            = local.tool_versions["KUBECTL_VERSION"]
    helm_version               = local.tool_versions["HELM_VERSION"]
    terraform_version          = local.tool_versions["TERRAFORM_VERSION"]
    awscli_version             = local.tool_versions["AWSCLI_VERSION"]
    runner_version             = var.runner_version
    runner_label               = var.runner_label
    runner_name                = var.name
    github_owner               = var.github_owner
    github_repo                = var.github_repo
    credential_source          = var.runner_credential_source
    credential_ssm_parameter   = var.credential_ssm_parameter
    github_app_id              = var.github_app_id
    github_app_installation_id = var.github_app_installation_id
    aws_region                 = var.aws_region
    teleport_version           = var.teleport_version
    install_teleport_tools     = var.install_teleport_tools
  })

  tags = { Name = var.name }

  lifecycle {
    ignore_changes = [ami]
  }
}
