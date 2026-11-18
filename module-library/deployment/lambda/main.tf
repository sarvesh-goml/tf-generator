data "aws_partition" "current" {}

locals {
  function_name = coalesce(var.function_name, "${var.name_prefix}-fn")
  source_dir    = coalesce(var.source_dir, "${path.module}/src")
}

data "archive_file" "this" {
  type        = "zip"
  source_dir  = local.source_dir
  output_path = "${path.root}/.build/${local.function_name}.zip"
}

# ---------------------------------------------------------------------------
# Logging (created before the function so retention is applied from day one)
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

# ---------------------------------------------------------------------------
# IAM
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name_prefix        = "${substr(var.name_prefix, 0, 28)}-fn-"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "basic" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "vpc" {
  count      = var.attach_to_vpc ? 1 : 0
  role       = aws_iam_role.this.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy_attachment" "xray" {
  count      = var.tracing_mode == "Active" ? 1 : 0
  role       = aws_iam_role.this.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

locals {
  grant_s3       = length(var.s3_bucket_arns) > 0
  grant_dynamodb = length(var.dynamodb_table_arns) > 0
}

data "aws_iam_policy_document" "service_access" {
  count = local.grant_s3 || local.grant_dynamodb ? 1 : 0

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
}

resource "aws_iam_role_policy" "service_access" {
  count  = local.grant_s3 || local.grant_dynamodb ? 1 : 0
  name   = "bundle-service-access"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.service_access[0].json
}

# ---------------------------------------------------------------------------
# Security group (only when attached to a VPC)
# ---------------------------------------------------------------------------
resource "aws_security_group" "this" {
  count = var.attach_to_vpc ? 1 : 0

  name_prefix = "${var.name_prefix}-fn-"
  description = "Security group for ${local.function_name}"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${local.function_name}-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_egress_rule" "all" {
  count = var.attach_to_vpc ? 1 : 0

  security_group_id = aws_security_group.this[0].id
  description       = "Allow all outbound traffic"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ---------------------------------------------------------------------------
# Function
# ---------------------------------------------------------------------------
resource "aws_lambda_function" "this" {
  function_name    = local.function_name
  role             = aws_iam_role.this.arn
  runtime          = var.runtime
  handler          = var.handler
  architectures    = [var.architecture]
  filename         = data.archive_file.this.output_path
  source_code_hash = data.archive_file.this.output_base64sha256
  memory_size      = var.memory_size
  timeout          = var.timeout

  reserved_concurrent_executions = var.reserved_concurrent_executions

  dynamic "environment" {
    for_each = length(var.environment_variables) > 0 ? [1] : []
    content {
      variables = var.environment_variables
    }
  }

  dynamic "vpc_config" {
    for_each = var.attach_to_vpc ? [1] : []
    content {
      subnet_ids         = var.subnet_ids
      security_group_ids = [aws_security_group.this[0].id]
    }
  }

  tracing_config {
    mode = var.tracing_mode
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition     = !var.attach_to_vpc || (var.vpc_id != null && length(var.subnet_ids) > 0)
      error_message = "Lambda in a VPC needs private subnets (the default VPC has none). Set vpc_create = true, or set lambda_attach_to_vpc = false."
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.this,
    aws_iam_role_policy_attachment.basic,
    aws_iam_role_policy_attachment.vpc,
  ]
}

# ---------------------------------------------------------------------------
# Add-on: function URL
# With authorization_type = NONE, the AWS provider (6.28+) also adds the
# lambda:InvokeFunctionUrl and URL-only lambda:InvokeFunction permissions AWS requires.
# ---------------------------------------------------------------------------
resource "aws_lambda_function_url" "this" {
  count = var.enable_function_url ? 1 : 0

  function_name      = aws_lambda_function.this.function_name
  authorization_type = var.function_url_auth_type
}

# ---------------------------------------------------------------------------
# Add-on: schedule (EventBridge)
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "schedule" {
  count = var.schedule_expression != null ? 1 : 0

  name                = substr("${local.function_name}-schedule", 0, 64)
  description         = "Runs ${local.function_name} on a schedule"
  schedule_expression = var.schedule_expression
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "schedule" {
  count = var.schedule_expression != null ? 1 : 0

  rule = aws_cloudwatch_event_rule.schedule[0].name
  arn  = aws_lambda_function.this.arn
}

resource "aws_lambda_permission" "schedule" {
  count = var.schedule_expression != null ? 1 : 0

  statement_id  = "AllowEventBridgeSchedule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.schedule[0].arn
}
