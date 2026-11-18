mock_provider "aws" {
  mock_resource "aws_cloudwatch_event_rule" {
    defaults = { arn = "arn:aws:events:us-east-1:111111111111:rule/mock" }
  }
  mock_resource "aws_lambda_function_url" {
    defaults = { function_url = "https://mock.lambda-url.us-east-1.on.aws/" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/mock" }
  }
  mock_resource "aws_lb" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:111111111111:loadbalancer/app/mock/abc" }
  }
  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:111111111111:targetgroup/mock/abc" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::mock-bucket" }
  }
  mock_resource "aws_dynamodb_table" {
    defaults = { arn = "arn:aws:dynamodb:us-east-1:111111111111:table/mock" }
  }
  mock_resource "aws_ecr_repository" {
    defaults = { arn = "arn:aws:ecr:us-east-1:111111111111:repository/mock" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-east-1:111111111111:log-group:mock" }
  }
  mock_resource "aws_ecs_cluster" {
    defaults = { arn = "arn:aws:ecs:us-east-1:111111111111:cluster/mock" }
  }
  mock_resource "aws_ecs_task_definition" {
    defaults = { arn = "arn:aws:ecs:us-east-1:111111111111:task-definition/mock:1" }
  }
  mock_resource "aws_lambda_function" {
    defaults = { arn = "arn:aws:lambda:us-east-1:111111111111:function:mock" }
  }
  mock_resource "aws_iam_instance_profile" {
    defaults = { arn = "arn:aws:iam::111111111111:instance-profile/mock" }
  }
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-1a", "us-east-1b", "us-east-1c"] }
  }
  mock_data "aws_vpc" {
    defaults = { id = "vpc-default", cidr_block = "172.31.0.0/16" }
  }
  mock_data "aws_subnets" {
    defaults = { ids = ["subnet-def-b", "subnet-def-a", "subnet-def-c"] }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { insecure_value = "ami-0123456789abcdef0" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_region" {
    defaults = { id = "us-east-1" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}
mock_provider "archive" {}

run "defaults_use_default_vpc_public" {
  command = plan
  assert {
    condition     = module.vpc.mode == "default"
    error_message = "default should use the default VPC"
  }
  assert {
    condition     = module.vpc.public_subnet_ids == tolist(["subnet-def-a", "subnet-def-b", "subnet-def-c"])
    error_message = "default VPC subnets should be discovered and sorted"
  }
  assert {
    condition     = length(module.vpc.private_subnet_ids) == 0
    error_message = "default VPC has no private subnets"
  }
  assert {
    condition     = length(module.vpc.nat_gateway_ids) == 0
    error_message = "no NAT for the default VPC"
  }
}

run "new_vpc_everything_private_https" {
  command = plan
  variables {
    vpc_create             = true
    vpc_az_count           = 3
    vpc_single_nat_gateway = false
    ec2_subnet_type        = "private"
    ecs_subnet_type        = "private"
    lambda_attach_to_vpc   = true
    ecs_certificate_arn    = "arn:aws:acm:us-east-1:111111111111:certificate/abc"
    ec2_ingress_rules = [
      { description = "https", from_port = 443, to_port = 443, ip_protocol = "tcp", cidr_ipv4 = "10.0.0.0/16" },
      { description = "all", from_port = 0, to_port = 0, ip_protocol = "-1", cidr_ipv4 = "10.0.0.0/8" },
    ]
    dynamodb_instances = {
      "1" = { range_key = "sk", ttl_attribute = "expires_at", billing_mode = "PROVISIONED" }
    }
  }
  assert {
    condition     = module.vpc.mode == "new" && length(module.vpc.nat_gateway_ids) == 3
    error_message = "expected a new VPC with 3 NAT gateways"
  }
}

run "new_vpc_mixed_public_private" {
  command = plan
  variables {
    vpc_create      = true
    ec2_subnet_type = "public"
    ecs_subnet_type = "private"
  }
}

run "existing_vpc_no_alb" {
  command = plan
  variables {
    vpc_existing_id                       = "vpc-0abc"
    vpc_existing_public_subnet_ids        = ["subnet-a", "subnet-b"]
    vpc_existing_private_subnet_ids       = ["subnet-c", "subnet-d"]
    ec2_subnet_type                       = "private"
    ec2_instances                         = { "1" = { subnet_id = "subnet-d" } }
    ecs_enable_load_balancer              = false
    s3_instances                          = { "1" = { bucket_name = "my-explicit-bucket" } }
    s3_noncurrent_version_expiration_days = null
  }
  assert {
    condition     = module.vpc.mode == "existing"
    error_message = "expected existing mode"
  }
}

run "bad_subnet_type_rejected" {
  command = plan
  variables {
    ec2_subnet_type = "dmz"
  }
  expect_failures = [var.ec2_subnet_type]
}

run "bad_project_name_rejected" {
  command = plan
  variables {
    project_name = "My_App"
  }
  expect_failures = [var.project_name]
}

run "case_clashing_tags_rejected" {
  command = plan
  variables {
    additional_tags = { project = "aimatic", owner = "sarve" }
  }
  expect_failures = [var.additional_tags]
}

run "extra_tags_accepted" {
  command = plan
  variables {
    additional_tags = { Owner = "sarve", CostCenter = "demo" }
  }
}

run "many_instances_with_overrides" {
  command = plan
  variables {
    vpc_create = true
    ec2_instances = {
      web    = {}
      worker = { instance_type = "t3.small", subnet_type = "private", root_volume_size = 40 }
      batch  = { architecture = "arm64", instance_type = "t4g.micro" }
    }
    ecs_instances = {
      api   = {}
      admin = { container_port = 8080, desired_count = 2, subnet_type = "private" }
    }
    lambda_instances = {
      orders  = { timeout = 30, environment_variables = { QUEUE = "orders" } }
      reports = { memory_size = 512, attach_to_vpc = true }
    }
    ecr_instances = { api = {}, admin = { image_tag_mutability = "MUTABLE" } }
    s3_instances  = { uploads = {}, logs = { enable_versioning = false } }
    dynamodb_instances = {
      users  = { hash_key = "user_id" }
      orders = { hash_key = "order_id", range_key = "created_at", range_key_type = "N" }
    }
  }
  assert {
    condition     = length(output.ec2_instance_id) == 3 && length(output.ecs_service_name) == 2
    error_message = "expected 3 EC2 instances and 2 ECS services"
  }
  assert {
    condition     = length(output.s3_bucket_arn) == 2 && length(output.dynamodb_table_arn) == 2
    error_message = "expected 2 buckets and 2 tables"
  }
  assert {
    condition     = output.lambda_function_name["orders"] == "myapp-dev-orders-fn"
    error_message = "instance key should be part of the resource name"
  }
}

run "zero_instances_of_a_service" {
  command = plan
  variables {
    s3_instances  = {}
    ecr_instances = {}
  }
  assert {
    condition     = length(output.s3_bucket_arn) == 0
    error_message = "an empty map should create no buckets"
  }
}

run "long_names_keep_load_balancers_unique" {
  command = plan
  variables {
    project_name  = "averyverylongproject"
    environment   = "production"
    ecs_instances = { checkout-servic = {}, checkout-servi2 = {} }
  }
}

run "bad_instance_key_rejected" {
  command = plan
  variables {
    ec2_instances = { "Web_Server" = {} }
  }
  expect_failures = [var.ec2_instances]
}

run "all_add_ons_with_per_instance_choices" {
  command = plan
  variables {
    vpc_create = true
    ec2_instances = {
      web    = { enable_elastic_ip = true, data_volume_size = 100 }
      worker = { subnet_type = "private", detailed_monitoring = true }
    }
    lambda_instances = {
      api     = { enable_function_url = true }
      private = { enable_function_url = true, function_url_auth = "AWS_IAM" }
      nightly = { schedule_expression = "cron(0 2 * * ? *)", enable_xray = true }
    }
    ecs_instances      = { api = { autoscaling_max_count = 6, desired_count = 2 } }
    ecs_enable_execute_command = true
    ecr_image_tag_mutability   = "MUTABLE"
    s3_instances               = { archive = { transition_to_ia_days = 60 }, uploads = {} }
    dynamodb_instances = {
      events = { stream_view_type = "NEW_IMAGE", ttl_attribute = "expires_at" }
    }
    dynamodb_deletion_protection = true
  }
  assert {
    condition     = output.ec2_elastic_ip["worker"] == null
    error_message = "only web should get an Elastic IP"
  }
  assert {
    condition     = length(output.lambda_function_url) == 3 && output.lambda_function_url["nightly"] == null
    error_message = "nightly should have no function URL"
  }
}
