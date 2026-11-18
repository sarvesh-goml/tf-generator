data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  container_name = "app"
  # ALB and target group names are limited to 32 characters. Long prefixes are cut
  # and given a short hash so two instances never end up with the same name.
  short_prefix = length(var.name_prefix) <= 27 ? var.name_prefix : "${substr(var.name_prefix, 0, 22)}-${substr(md5(var.name_prefix), 0, 4)}"
  lb_name      = "${local.short_prefix}-alb"
  tg_name      = "${local.short_prefix}-tg"

  https_enabled = var.enable_load_balancer && var.certificate_arn != null
  task_subnets  = var.subnet_type == "public" ? var.public_subnet_ids : var.private_subnet_ids
}

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------
resource "aws_ecs_cluster" "this" {
  name = "${var.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = var.enable_container_insights ? "enabled" : "disabled"
  }

  tags = var.tags
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.name_prefix}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

# ---------------------------------------------------------------------------
# IAM: execution role (ECS agent) and task role (your application)
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name_prefix        = "${substr(var.name_prefix, 0, 26)}-ecsx-"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task" {
  name_prefix        = "${substr(var.name_prefix, 0, 26)}-ecst-"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
  tags               = var.tags
}

locals {
  grant_s3       = length(var.s3_bucket_arns) > 0
  grant_dynamodb = length(var.dynamodb_table_arns) > 0
  grant_any      = local.grant_s3 || local.grant_dynamodb || var.enable_execute_command
}

data "aws_iam_policy_document" "task" {
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
    for_each = var.enable_execute_command ? [1] : []
    content {
      sid = "EcsExec"
      actions = [
        "ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel",
      ]
      resources = ["*"]
    }
  }
}

resource "aws_iam_role_policy" "task" {
  count  = local.grant_any ? 1 : 0
  name   = "bundle-service-access"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task[0].json
}

# ---------------------------------------------------------------------------
# Task definition
# ---------------------------------------------------------------------------
resource "aws_ecs_task_definition" "this" {
  family                   = var.name_prefix
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  container_definitions = jsonencode([
    {
      name      = local.container_name
      image     = var.container_image
      essential = true
      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]
      environment = [for k, v in var.environment_variables : { name = k, value = v }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.this.name
          awslogs-region        = data.aws_region.current.id
          awslogs-stream-prefix = local.container_name
        }
      }
    }
  ])

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Security groups
# ---------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  count = var.enable_load_balancer ? 1 : 0

  name_prefix = "${var.name_prefix}-alb-"
  description = "ALB for ${var.name_prefix}"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name_prefix}-alb-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb" {
  for_each = var.enable_load_balancer ? {
    for pair in setproduct(local.https_enabled ? [80, 443] : [80], var.alb_ingress_cidrs) :
    "${pair[0]}-${pair[1]}" => { port = pair[0], cidr = pair[1] }
  } : {}

  security_group_id = aws_security_group.alb[0].id
  description       = "Inbound ${each.value.port}"
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = each.value.cidr
}

resource "aws_vpc_security_group_egress_rule" "alb" {
  count = var.enable_load_balancer ? 1 : 0

  security_group_id = aws_security_group.alb[0].id
  description       = "Allow all outbound traffic"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "service" {
  name_prefix = "${var.name_prefix}-svc-"
  description = "ECS tasks for ${var.name_prefix}"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name_prefix}-svc-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "service_from_alb" {
  count = var.enable_load_balancer ? 1 : 0

  security_group_id            = aws_security_group.service.id
  description                  = "Traffic from the ALB"
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
  referenced_security_group_id = aws_security_group.alb[0].id
}

resource "aws_vpc_security_group_ingress_rule" "service_direct" {
  for_each = var.enable_load_balancer ? toset([]) : toset(var.service_ingress_cidrs)

  security_group_id = aws_security_group.service.id
  description       = "Direct access to tasks"
  ip_protocol       = "tcp"
  from_port         = var.container_port
  to_port           = var.container_port
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "service" {
  security_group_id = aws_security_group.service.id
  description       = "Allow all outbound traffic"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ---------------------------------------------------------------------------
# Application Load Balancer
# ---------------------------------------------------------------------------
resource "aws_lb" "this" {
  count = var.enable_load_balancer ? 1 : 0

  name                       = local.lb_name
  load_balancer_type         = "application"
  internal                   = false
  subnets                    = var.public_subnet_ids
  security_groups            = [aws_security_group.alb[0].id]
  drop_invalid_header_fields = true

  tags = var.tags

  lifecycle {
    precondition {
      condition     = length(var.public_subnet_ids) >= 2
      error_message = "The load balancer needs public subnets in at least two availability zones. Use vpc_az_count >= 2, or set ecs_enable_load_balancer = false."
    }
  }
}

resource "aws_lb_target_group" "this" {
  count = var.enable_load_balancer ? 1 : 0

  name                 = local.tg_name
  port                 = var.container_port
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = 30

  health_check {
    path                = var.health_check_path
    matcher             = "200-399"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
  }

  tags = var.tags
}

resource "aws_lb_listener" "http" {
  count = var.enable_load_balancer ? 1 : 0

  load_balancer_arn = aws_lb.this[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = local.https_enabled ? "redirect" : "forward"
    target_group_arn = local.https_enabled ? null : aws_lb_target_group.this[0].arn

    dynamic "redirect" {
      for_each = local.https_enabled ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }
}

resource "aws_lb_listener" "https" {
  count = local.https_enabled ? 1 : 0

  load_balancer_arn = aws_lb.this[0].arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[0].arn
  }
}

# ---------------------------------------------------------------------------
# Service
# ---------------------------------------------------------------------------
resource "aws_ecs_service" "this" {
  name                   = "${var.name_prefix}-svc"
  cluster                = aws_ecs_cluster.this.id
  task_definition        = aws_ecs_task_definition.this.arn
  desired_count          = var.desired_count
  launch_type            = "FARGATE"
  enable_execute_command = var.enable_execute_command
  propagate_tags         = "SERVICE"

  health_check_grace_period_seconds = var.enable_load_balancer ? 60 : null

  network_configuration {
    subnets          = local.task_subnets
    security_groups  = [aws_security_group.service.id]
    assign_public_ip = var.subnet_type == "public"
  }

  dynamic "load_balancer" {
    for_each = var.enable_load_balancer ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.this[0].arn
      container_name   = local.container_name
      container_port   = var.container_port
    }
  }

  # Roll back automatically if a new deployment never becomes healthy.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition     = length(local.task_subnets) > 0
      error_message = "No ${var.subnet_type} subnets available for ECS tasks. The default VPC has only public subnets: set ecs_subnet_type = \"public\", or set vpc_create = true to get private subnets."
    }
  }

  depends_on = [
    aws_lb_listener.http,
    aws_lb_listener.https,
    aws_iam_role_policy_attachment.execution,
  ]
}

# ---------------------------------------------------------------------------
# Add-on: auto scaling on CPU
# ---------------------------------------------------------------------------
resource "aws_appautoscaling_target" "this" {
  count = var.autoscaling_max_count > 0 ? 1 : 0

  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.this.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.desired_count
  max_capacity       = var.autoscaling_max_count

  lifecycle {
    precondition {
      condition     = var.autoscaling_max_count >= var.desired_count
      error_message = "autoscaling_max_count must be at least desired_count."
    }
  }
}

resource "aws_appautoscaling_policy" "cpu" {
  count = var.autoscaling_max_count > 0 ? 1 : 0

  name               = "${var.name_prefix}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this[0].service_namespace
  resource_id        = aws_appautoscaling_target.this[0].resource_id
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = var.autoscaling_cpu_target
    scale_in_cooldown  = 300
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
