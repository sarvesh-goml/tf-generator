data "aws_partition" "current" {}

# Latest Amazon Linux 2023 AMI, published by AWS as a public SSM parameter.
data "aws_ssm_parameter" "al2023" {
  count = var.ami_id == null ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${var.architecture}"
}

locals {
  ami_id = var.ami_id != null ? var.ami_id : one(data.aws_ssm_parameter.al2023[*].insecure_value)

  candidate_subnets = var.subnet_type == "public" ? var.public_subnet_ids : var.private_subnet_ids
  subnet_id         = var.subnet_id != null ? var.subnet_id : try(element(local.candidate_subnets, var.subnet_index), null)
}

# ---------------------------------------------------------------------------
# Security group
# ---------------------------------------------------------------------------
resource "aws_security_group" "this" {
  name_prefix = "${var.name_prefix}-ec2-"
  description = "Security group for ${var.name_prefix} EC2 instance"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name_prefix}-ec2-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "this" {
  for_each = { for idx, rule in var.ingress_rules : tostring(idx) => rule }

  security_group_id = aws_security_group.this.id
  description       = each.value.description
  ip_protocol       = each.value.ip_protocol
  from_port         = each.value.ip_protocol == "-1" ? null : each.value.from_port
  to_port           = each.value.ip_protocol == "-1" ? null : each.value.to_port
  cidr_ipv4         = each.value.cidr_ipv4
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  description       = "Allow all outbound traffic"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ---------------------------------------------------------------------------
# IAM role + instance profile
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name_prefix        = "${substr(var.name_prefix, 0, 28)}-ec2-"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  count      = var.enable_ssm ? 1 : 0
  role       = aws_iam_role.this.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "this" {
  name_prefix = "${substr(var.name_prefix, 0, 28)}-ec2-"
  role        = aws_iam_role.this.name
  tags        = var.tags
}

# Least-privilege access to other services in the same bundle.
locals {
  grant_s3       = length(var.s3_bucket_arns) > 0
  grant_dynamodb = length(var.dynamodb_table_arns) > 0
  grant_ecr      = length(var.ecr_repository_arns) > 0
  grant_any      = local.grant_s3 || local.grant_dynamodb || local.grant_ecr
}

data "aws_iam_policy_document" "service_access" {
  count = local.grant_any ? 1 : 0

  dynamic "statement" {
    for_each = local.grant_s3 ? [1] : []
    content {
      sid       = "S3Bucket"
      actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
      resources = var.s3_bucket_arns
    }
  }

  dynamic "statement" {
    for_each = local.grant_s3 ? [1] : []
    content {
      sid       = "S3Objects"
      actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
      resources = [for arn in var.s3_bucket_arns : "${arn}/*"]
    }
  }

  dynamic "statement" {
    for_each = local.grant_dynamodb ? [1] : []
    content {
      sid = "DynamoDB"
      actions = [
        "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem",
        "dynamodb:Query", "dynamodb:Scan", "dynamodb:BatchGetItem", "dynamodb:BatchWriteItem",
        "dynamodb:DescribeTable",
      ]
      resources = concat(var.dynamodb_table_arns, [for arn in var.dynamodb_table_arns : "${arn}/index/*"])
    }
  }

  dynamic "statement" {
    for_each = local.grant_ecr ? [1] : []
    content {
      sid       = "EcrAuth"
      actions   = ["ecr:GetAuthorizationToken"]
      resources = ["*"]
    }
  }

  dynamic "statement" {
    for_each = local.grant_ecr ? [1] : []
    content {
      sid       = "EcrPull"
      actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
      resources = var.ecr_repository_arns
    }
  }
}

resource "aws_iam_role_policy" "service_access" {
  count  = local.grant_any ? 1 : 0
  name   = "bundle-service-access"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.service_access[0].json
}

# ---------------------------------------------------------------------------
# Instance
# ---------------------------------------------------------------------------
resource "aws_instance" "this" {
  ami                         = local.ami_id
  instance_type               = var.instance_type
  subnet_id                   = local.subnet_id
  vpc_security_group_ids      = [aws_security_group.this.id]
  iam_instance_profile        = aws_iam_instance_profile.this.name
  key_name                    = var.key_name
  associate_public_ip_address = var.subnet_type == "public"
  user_data                   = var.user_data
  monitoring                  = var.detailed_monitoring

  # Enforce IMDSv2.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = var.root_volume_type
    encrypted             = true
    delete_on_termination = true
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-ec2" })

  lifecycle {
    # A newer AMI in the SSM parameter should not replace a running instance.
    ignore_changes = [ami]

    precondition {
      condition     = local.subnet_id != null
      error_message = "No ${var.subnet_type} subnet available for EC2. The default VPC has only public subnets: set ec2_subnet_type = \"public\", or set vpc_create = true to get private subnets."
    }
  }
}

# ---------------------------------------------------------------------------
# Add-on: Elastic IP
# ---------------------------------------------------------------------------
resource "aws_eip" "this" {
  count = var.create_elastic_ip ? 1 : 0

  domain   = "vpc"
  instance = aws_instance.this.id
  tags     = merge(var.tags, { Name = "${var.name_prefix}-eip" })

  lifecycle {
    precondition {
      condition     = var.subnet_type == "public"
      error_message = "An Elastic IP only works for an instance in a public subnet. Set subnet_type = \"public\" for this instance, or turn the Elastic IP off."
    }
  }
}

# ---------------------------------------------------------------------------
# Add-on: extra data disk
# ---------------------------------------------------------------------------
resource "aws_ebs_volume" "data" {
  count = var.data_volume_size > 0 ? 1 : 0

  availability_zone = aws_instance.this.availability_zone
  size              = var.data_volume_size
  type              = "gp3"
  encrypted         = true
  tags              = merge(var.tags, { Name = "${var.name_prefix}-data" })
}

resource "aws_volume_attachment" "data" {
  count = var.data_volume_size > 0 ? 1 : 0

  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data[0].id
  instance_id = aws_instance.this.id
}
