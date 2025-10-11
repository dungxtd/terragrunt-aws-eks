# configure terragrunt behaviours with these
locals {
  ENVIRONMENT_NAME = get_env("ENVIRONMENT_NAME", "development")
  config           = yamldecode(file("../../environments/${get_env("ENVIRONMENT_NAME", "development")}/config.yaml"))
  default_outputs  = {}
  ecs_enabled      = try(local.config.ecs, null) != null
}

include "tf_main_config" {
  path = find_in_parent_folders()
}

skip = !local.ecs_enabled

dependencies {
  paths = [
    "../../tg-modules//vpc"
  ]
}

dependency "vpc" {
  config_path                             = "../../tg-modules//vpc"
  skip_outputs                            = false
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "destroy"]
  mock_outputs = {
    vpcs = merge([
      for vpc_region_k, vpc_region_v in try(local.config.network.vpc.regions, {}) : {
        for vpc_name, vpc_values in vpc_region_v :
        "vpc_${vpc_region_k}_${vpc_name}" => {
          "vpc_info" : { "vpc_id" : "a1b2c3" },
          "subnets_info" : merge([
            for sn_name, sn_values in vpc_values.subnets :
            { "subnet_${vpc_region_k}_${vpc_name}_${sn_name}" = { "public_subnet_ids" : ["snid123"], "private_subnet_ids" : ["snid123"] } }
          ]...)
        }
      }
    ]...)
  }
}

inputs = {
  vpcs_json = dependency.vpc.outputs.vpcs
}

generate "dynamic-ecs-modules" {
  path      = "dynamic-ecs-modules.tf"
  if_exists = "overwrite"
  contents  = <<EOF

locals {
  environment = "${chomp(try(local.config.general.environment, "development", local.ENVIRONMENT_NAME))}"
  env_short   = "${chomp(try(local.config.general.env-short, "dev"))}"
  project     = "${chomp(try(local.config.general.project, "PROJECT_NAME"))}"
}

%{for ecs_region_k, ecs_region_v in try(local.config.ecs.regions, {})~}
  %{for ecs_cluster_name, ecs_cluster_values in ecs_region_v~}

# ECS Cluster
resource "aws_ecs_cluster" "ecs_cluster_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}" {
  provider = aws.${ecs_region_k}
  
  name = "$${local.env_short}-${ecs_cluster_name}-${ecs_region_k}"

  setting {
    name  = "containerInsights"
    value = "${chomp(try(ecs_cluster_values["container-insights"], "enabled"))}"
  }



  tags = {
    Environment = "$${local.environment}"
    Project     = "$${local.project}"
  }
}

    %{for lb_name, lb_values in try(ecs_cluster_values["load-balancers"], {})~}

# Security Group for Load Balancer
resource "aws_security_group" "ecs_lb_sg_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(lb_name, "-", "_"), ".", "_")}" {
  provider = aws.${ecs_region_k}
  
  name        = "$${local.env_short}-${ecs_cluster_name}-${lb_name}-sg"
  description = "Security group for ECS load balancer ${lb_name}"
  vpc_id      = jsondecode(var.vpcs_json).vpc_${ecs_region_k}_${lb_values.vpc}.vpc_info.vpc_id

  %{for ingress_rule in try(lb_values["security-group"].ingress, [])~}
  ingress {
    description = "${try(ingress_rule.description, "")}"
    from_port   = ${ingress_rule["from-port"]}
    to_port     = ${ingress_rule["to-port"]}
    protocol    = "${ingress_rule.protocol}"
    cidr_blocks = [%{for cidr in try(ingress_rule["cidr-blocks"], [])~}"${cidr}", %{endfor~}]
  }
  %{endfor~}

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Environment = "$${local.environment}"
    Project     = "$${local.project}"
  }
}

# Application Load Balancer
resource "aws_lb" "ecs_lb_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(lb_name, "-", "_"), ".", "_")}" {
  provider = aws.${ecs_region_k}
  
  name               = "$${local.env_short}-${ecs_cluster_name}-${lb_name}"
  internal           = ${lower(chomp(try(lb_values.scheme, "internet-facing"))) == "internal"}
  load_balancer_type = "${lower(chomp(try(lb_values.type, "alb"))) == "alb" ? "application" : lower(chomp(try(lb_values.type, "alb")))}"
  security_groups    = [aws_security_group.ecs_lb_sg_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(lb_name, "-", "_"), ".", "_")}.id]

  subnets = concat(
    %{for subnet in try(lb_values.subnets, [])~}
    jsondecode(var.vpcs_json).vpc_${ecs_region_k}_${lb_values.vpc}.subnets_info.subnet_${ecs_region_k}_${lb_values.vpc}_${subnet.name}.${subnet.kind}_subnet_ids,
    %{endfor~}
  )

  enable_deletion_protection = false

  tags = {
    Environment = "$${local.environment}"
    Project     = "$${local.project}"
  }
}

      %{for listener_name, listener_config in try(lb_values.listeners, {})~}

# Load Balancer Listener
resource "aws_lb_listener" "ecs_lb_listener_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(lb_name, "-", "_"), ".", "_")}_${replace(replace(listener_name, "-", "_"), ".", "_")}" {
  provider = aws.${ecs_region_k}
  
  load_balancer_arn = aws_lb.ecs_lb_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(lb_name, "-", "_"), ".", "_")}.arn
  port              = "${listener_config["listener-port"]}"
  protocol          = "${upper(listener_config["listener-protocol"])}"

  default_action {
    type = "${lower(try(listener_config["default-action"].type, "fixed-response"))}"
    
    %{if try(listener_config["default-action"]["fixed-response"], null) != null~}
    fixed_response {
      content_type = "${try(listener_config["default-action"]["fixed-response"]["content-type"], "text/plain")}"
      message_body = "${try(listener_config["default-action"]["fixed-response"]["message-body"], "Not Found")}"
      status_code  = "${try(listener_config["default-action"]["fixed-response"]["status-code"], "404")}"
    }
    %{endif~}
  }

  tags = {
    Environment = "$${local.environment}"
    Project     = "$${local.project}"
  }
}

      %{endfor~}

    %{for service_name, service_values in try(ecs_cluster_values.services, {})~}

    # Security Group for ECS Service
    resource "aws_security_group" "ecs_service_sg_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(service_name, "-", "_"), ".", "_")}" {
      provider = aws.${ecs_region_k}
      name        = "$${local.environment}-${service_name}-sg"
      description = "Security group for ${service_name} ECS service"
      vpc_id      = jsondecode(var.vpcs_json).vpc_${ecs_region_k}_${try(ecs_cluster_values["load-balancers"]["public-alb"].vpc, local.config.network.default_vpc)}.vpc_info.vpc_id

      ingress {
        from_port       = 80
        to_port         = 80
        protocol        = "tcp"
        security_groups = [aws_security_group.ecs_lb_sg_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_public_alb.id]
      }

      egress {
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = ["0.0.0.0/0"]
      }

      tags = {
        Environment = "$${local.environment}"
        Project     = "$${local.project}"
      }
    }

    # Task Definition
    resource "aws_ecs_task_definition" "ecs_task_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(service_name, "-", "_"), ".", "_")}" {
      provider = aws.${ecs_region_k}
      family                   = "${service_values["task-definition"].family}"
      network_mode             = "${service_values["task-definition"].network-mode}"
      requires_compatibilities = ${jsonencode(service_values["task-definition"]["requires-compatibilities"])}
      cpu                      = "${service_values["task-definition"].cpu}"
      memory                   = "${service_values["task-definition"].memory}"
      execution_role_arn       = "${service_values["task-definition"]["execution-role-arn"]}"
      container_definitions    = jsonencode([
        {
          name = "${service_values["task-definition"]["container-definitions"][0].name}"
          image = "${service_values["task-definition"]["container-definitions"][0].image}"
          portMappings = [
            {
              containerPort = ${service_values["task-definition"]["container-definitions"][0]["port-mappings"][0]["container-port"]}
              protocol = "${service_values["task-definition"]["container-definitions"][0]["port-mappings"][0].protocol}"
            }
          ]
          logConfiguration = {
            logDriver = "${service_values["task-definition"]["container-definitions"][0]["log-configuration"]["log-driver"]}"
            options = {
              "awslogs-group" = "${service_values["task-definition"]["container-definitions"][0]["log-configuration"].options["awslogs-group"]}"
              "awslogs-region" = "${service_values["task-definition"]["container-definitions"][0]["log-configuration"].options["awslogs-region"]}"
              "awslogs-stream-prefix" = "${service_values["task-definition"]["container-definitions"][0]["log-configuration"].options["awslogs-stream-prefix"]}"
            }
          }
        }
      ])

      tags = {
        Environment = "$${local.environment}"
        Project     = "$${local.project}"
      }
    }

    # Target Group
    resource "aws_lb_target_group" "ecs_tg_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(service_name, "-", "_"), ".", "_")}" {
      provider = aws.${ecs_region_k}
      name        = "${service_values["load-balancer"]["target-group"].name}"
      port        = ${service_values["load-balancer"]["target-group"].port}
      protocol    = "${service_values["load-balancer"]["target-group"].protocol}"
      target_type = "${service_values["load-balancer"]["target-group"]["target-type"]}"
      vpc_id      = jsondecode(var.vpcs_json).vpc_${ecs_region_k}_${try(ecs_cluster_values["load-balancers"]["public-alb"].vpc, local.config.network.default_vpc)}.vpc_info.vpc_id

      health_check {
        enabled             = ${service_values["load-balancer"]["target-group"]["health-check"].enabled}
        healthy_threshold   = ${service_values["load-balancer"]["target-group"]["health-check"]["healthy-threshold-count"]}
        interval            = ${service_values["load-balancer"]["target-group"]["health-check"]["interval-seconds"]}
        matcher             = "${service_values["load-balancer"]["target-group"]["health-check"].matcher}"
        path                = "${service_values["load-balancer"]["target-group"]["health-check"].path}"
        port                = "${service_values["load-balancer"]["target-group"]["health-check"].port}"
        protocol            = "${service_values["load-balancer"]["target-group"]["health-check"].protocol}"
        timeout             = ${service_values["load-balancer"]["target-group"]["health-check"]["timeout-seconds"]}
        unhealthy_threshold = ${service_values["load-balancer"]["target-group"]["health-check"]["unhealthy-threshold-count"]}
      }

      tags = {
        Environment = "$${local.environment}"
        Project     = "$${local.project}"
      }
    }

    # Listener Rule
    resource "aws_lb_listener_rule" "ecs_rule_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(service_name, "-", "_"), ".", "_")}" {
      provider = aws.${ecs_region_k}
      listener_arn = aws_lb_listener.ecs_lb_listener_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_public_alb_http.arn
      priority     = ${service_values["load-balancer"]["listener-rule"].priority}

      action {
        type             = "forward"
        target_group_arn = aws_lb_target_group.ecs_tg_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(service_name, "-", "_"), ".", "_")}.arn
      }

      condition {
        path_pattern {
          values = ${jsonencode(service_values["load-balancer"]["listener-rule"].conditions[0].values)}
        }
      }

      tags = {
        Environment = "$${local.environment}"
        Project     = "$${local.project}"
      }
    }

    # ECS Service
    resource "aws_ecs_service" "ecs_service_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(service_name, "-", "_"), ".", "_")}" {
      provider = aws.${ecs_region_k}
      name            = "${service_name}"
      cluster         = aws_ecs_cluster.ecs_cluster_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}.id
      task_definition = aws_ecs_task_definition.ecs_task_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(service_name, "-", "_"), ".", "_")}.arn
      desired_count   = ${service_values.service["desired-count"]}
      launch_type     = "${service_values.service["launch-type"]}"
      platform_version = "${service_values.service["platform-version"]}"

      network_configuration {
        subnets = jsondecode(var.vpcs_json).vpc_${ecs_region_k}_${try(ecs_cluster_values["load-balancers"]["public-alb"].vpc, local.config.network.default_vpc)}.subnets_info.subnet_${ecs_region_k}_${try(ecs_cluster_values["load-balancers"]["public-alb"].vpc, local.config.network.default_vpc)}_default.private_subnet_ids
        security_groups = [aws_security_group.ecs_service_sg_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(service_name, "-", "_"), ".", "_")}.id]
      }

      load_balancer {
        target_group_arn = aws_lb_target_group.ecs_tg_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(service_name, "-", "_"), ".", "_")}.arn
        container_name   = "${service_values["task-definition"]["container-definitions"][0].name}"
        container_port   = ${service_values["task-definition"]["container-definitions"][0]["port-mappings"][0]["container-port"]}
      }

      depends_on = [aws_lb_listener.ecs_lb_listener_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_public_alb_http]

      tags = {
        Environment = "$${local.environment}"
        Project     = "$${local.project}"
      }
    }
    %{endfor~}
    %{endfor~}
  %{endfor~}
%{endfor~}

EOF
}

generate "dynamic-ecs-outputs" {
  path      = "dynamic-ecs-outputs.tf"
  if_exists = "overwrite"
  contents  = <<EOF

output "ecs_clusters" {
  value = merge(
%{for ecs_region_k, ecs_region_v in try(local.config.ecs.regions, {})~}
  %{for ecs_cluster_name, ecs_cluster_values in ecs_region_v~}
    {
      "ecs_cluster_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}" = {
        "cluster_arn"  = aws_ecs_cluster.ecs_cluster_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}.arn
        "cluster_name" = aws_ecs_cluster.ecs_cluster_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}.name
      }
    },
  %{endfor~}
%{endfor~}
  )
}

output "ecs_load_balancers" {
  value = merge(
%{for ecs_region_k, ecs_region_v in try(local.config.ecs.regions, {})~}
  %{for ecs_cluster_name, ecs_cluster_values in ecs_region_v~}
    %{for lb_name, lb_values in try(ecs_cluster_values["load-balancers"], {})~}
    {
      "ecs_lb_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(lb_name, "-", "_"), ".", "_")}" = {
        "arn"      = aws_lb.ecs_lb_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(lb_name, "-", "_"), ".", "_")}.arn
        "dns_name" = aws_lb.ecs_lb_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(lb_name, "-", "_"), ".", "_")}.dns_name
      }
    },
    %{endfor~}
  %{endfor~}
%{endfor~}
  )
}

output "ecs_services" {
  value = merge(
%{for ecs_region_k, ecs_region_v in try(local.config.ecs.regions, {})~}
  %{for ecs_cluster_name, ecs_cluster_values in ecs_region_v~}
    %{for service_name, service_values in try(ecs_cluster_values.services, {})~}
    {
      "ecs_service_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(service_name, "-", "_"), ".", "_")}" = {
        "service_arn"  = aws_ecs_service.ecs_service_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(service_name, "-", "_"), ".", "_")}.id
        "service_name" = aws_ecs_service.ecs_service_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(service_name, "-", "_"), ".", "_")}.name
        "task_definition_arn" = aws_ecs_task_definition.ecs_task_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(service_name, "-", "_"), ".", "_")}.arn
        "target_group_arn" = aws_lb_target_group.ecs_tg_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(service_name, "-", "_"), ".", "_")}.arn
      }
    },
    %{endfor~}
  %{endfor~}
%{endfor~}
  )
}

EOF
}

terraform {
  before_hook "terraform_fmt" {
    commands = ["apply", "plan", "destroy"]
    execute  = ["terraform", "fmt", "-recursive"]
  }

  source = ".//."
}
