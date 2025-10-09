# configure terragrunt behaviours with these
locals {
  ENVIRONMENT_NAME = get_env("ENVIRONMENT_NAME", "development")
  config           = yamldecode(file("../../environments/${get_env("ENVIRONMENT_NAME", "development")}/config.yaml"))
  default_outputs  = {}
}

include "tf_main_config" {
  path = find_in_parent_folders()
}

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

module "ecs_cluster_label_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}" {

  source  = "cloudposse/label/null"
  version = "0.25.0"

  stage      = ""
  namespace  = ""
  name       = "$${local.env_short}-${ecs_cluster_name}-${ecs_region_k}"
  delimiter  = "-"
  attributes = ["cluster"]
}

resource "aws_ecs_cluster" "ecs_cluster_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}" {

  provider = aws.${ecs_region_k}

  %{if try(ecs_cluster_values.name, "") != ""}
  name = "${chomp(ecs_cluster_values.name)}"
  %{else}
  name = format("%s-%s-%s", local.env_short, "${replace(ecs_cluster_name, "_", "-")}", "${replace(ecs_region_k, "_", "-")}")
  %{endif~}

  setting {
    name  = "containerInsights"
    value = chomp(try(ecs_cluster_values["container-insights"], "enabled"))
  }

  %{if try(ecs_cluster_values["capacity-providers"], "") != ""}
  capacity_providers = [
    %{for provider in ecs_cluster_values["capacity-providers"]~}
    "${provider}",
    %{endfor~}
  ]
  %{endif~}

  tags = merge({
    Environment = local.environment
    Project     = local.project
  }, try(ecs_cluster_values.tags, {}))
}

  %{if try(ecs_cluster_values["capacity-providers"], "") != ""}

resource "aws_ecs_cluster_capacity_providers" "ecs_cluster_capacity_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}" {

  provider = aws.${ecs_region_k}

  cluster_name = aws_ecs_cluster.ecs_cluster_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}.name

  capacity_providers = [
    %{for provider in ecs_cluster_values["capacity-providers"]~}
    "${provider}",
    %{endfor~}
  ]

  dynamic "default_capacity_provider_strategy" {
    for_each = try(ecs_cluster_values["default-capacity-provider-strategy"], [])
    content {
      capacity_provider = default_capacity_provider_strategy.value["capacity-provider"]
      weight            = try(default_capacity_provider_strategy.value.weight, null)
      base              = try(default_capacity_provider_strategy.value.base, null)
    }
  }
}

  %{endif~}

    %{for lb_name, lb_values in try(ecs_cluster_values["load-balancers"], {})~}

locals {
  ecs_cluster_${replace(replace(replace(ecs_region_k, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(lb_name, "-", "_"), ".", "_"), " ", "_")}_subnet_ids = distinct(flatten([
    %{for subnet in try(lb_values.subnets, [])~}
    jsondecode(var.vpcs_json).vpc_${try(lb_values.region, ecs_region_k)}_${lb_values.vpc}.subnets_info.subnet_${try(lb_values.region, ecs_region_k)}_${lb_values.vpc}_${subnet.name}.${subnet.kind}_subnet_ids,
    %{endfor~}
  ]))
}

    %{if lower(try(lb_values.type, "alb")) == "alb" && try(lb_values["security-group"], null) != null}

resource "aws_security_group" "ecs_cluster_lb_sg_${replace(replace(replace(ecs_region_k, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(ecs_cluster_name, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(lb_name, "-", "_"), ".", "_"), " ", "_")}" {

  provider = aws.${ecs_region_k}

  name = chomp(try(lb_values["security-group"].name, format("%s-%s-%s-alb-sg", local.env_short, "${replace(ecs_cluster_name, "_", "-")}", "${replace(lb_name, "_", "-")}")))
  description = chomp(try(lb_values["security-group"].description, "Security group for shared ECS load balancer ${lb_name}"))
  vpc_id      = jsondecode(var.vpcs_json).vpc_${try(lb_values.region, ecs_region_k)}_${lb_values.vpc}.vpc_info.vpc_id

  revoke_rules_on_delete = true

  dynamic "ingress" {
    for_each = try(lb_values["security-group"].ingress, [])
    content {
      description      = try(ingress.value.description, "")
      from_port        = ingress.value["from-port"]
      to_port          = ingress.value["to-port"]
      protocol         = ingress.value.protocol
      cidr_blocks      = try(ingress.value["cidr-blocks"], [])
      ipv6_cidr_blocks = try(ingress.value["ipv6-cidr-blocks"], [])
      security_groups  = try(ingress.value["security-groups"], [])
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Environment = local.environment
    Project     = local.project
  }
}

    %{endif~}

resource "aws_lb" "ecs_cluster_lb_${replace(replace(replace(ecs_region_k, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(ecs_cluster_name, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(lb_name, "-", "_"), ".", "_"), " ", "_")}" {

  provider = aws.${ecs_region_k}

  name               = substr(format("%s-%s-%s-%s", local.env_short, "${replace(ecs_cluster_name, "_", "-")}", "${replace(ecs_region_k, "_", "-")}", "${replace(lb_name, "_", "-")}"), 0, 32)
  internal           = lower(chomp(try(lb_values.scheme, "internet-facing"))) == "internal"
  load_balancer_type = lower(chomp(try(lb_values.type, "alb"))) == "nlb" ? "network" : "application"

  subnets = local.ecs_cluster_${replace(replace(replace(ecs_region_k, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(lb_name, "-", "_"), ".", "_"), " ", "_")}_subnet_ids

  security_groups = lower(chomp(try(lb_values.type, "alb"))) == "alb" && try(lb_values["security-group"], null) != null ? [
    aws_security_group.ecs_cluster_lb_sg_${replace(replace(replace(ecs_region_k, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(ecs_cluster_name, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(lb_name, "-", "_"), ".", "_"), " ", "_")}.id
  ] : null

  enable_http2 = lower(chomp(try(lb_values.type, "alb"))) == "alb" ? try(lb_values["enable-http2"], true) : null
  enable_cross_zone_load_balancing = lower(chomp(try(lb_values.type, "alb"))) == "nlb" ? try(lb_values["enable-cross-zone-load-balancing"], true) : null

  tags = merge({
    Environment = local.environment
    Project     = local.project
  }, try(lb_values.tags, {}))
}

    %{for listener_name, listener_config in try(lb_values.listeners, {})~}

resource "aws_lb_listener" "ecs_cluster_lb_listener_${replace(replace(replace(ecs_region_k, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(ecs_cluster_name, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(lb_name, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(listener_name, "-", "_"), ".", "_"), " ", "_")}" {

  provider = aws.${ecs_region_k}

  load_balancer_arn = aws_lb.ecs_cluster_lb_${replace(replace(replace(ecs_region_k, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(ecs_cluster_name, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(lb_name, "-", "_"), ".", "_"), " ", "_")}.arn
  port              = listener_config["listener-port"]
  protocol          = upper(listener_config["listener-protocol"])
  ssl_policy        = upper(listener_config["listener-protocol"]) == "HTTPS" ? try(listener_config["ssl-policy"], "ELBSecurityPolicy-2016-08") : null
  certificate_arn   = upper(listener_config["listener-protocol"]) == "HTTPS" ? try(listener_config["certificate-arn"], null) : null

  %{if try(listener_config["default-action"], null) != null}
  default_action {
    %{if lower(try(listener_config["default-action"].type, "")) == "redirect"}
    type = "REDIRECT"
    redirect {
      status_code = try(listener_config["default-action"]["redirect"]["status-code"], "302")
      host        = try(listener_config["default-action"]["redirect"]["host"], null)
      path        = try(listener_config["default-action"]["redirect"]["path"], null)
      port        = try(listener_config["default-action"]["redirect"]["port"], null)
      protocol    = try(listener_config["default-action"]["redirect"]["protocol"], null)
      query       = try(listener_config["default-action"]["redirect"]["query"], null)
    }
    %{else}
    type = "FIXED-RESPONSE"
    fixed_response {
      status_code  = try(listener_config["default-action"]["fixed-response"]["status-code"], "404")
      content_type = try(listener_config["default-action"]["fixed-response"]["content-type"], "text/plain")
      message_body = try(listener_config["default-action"]["fixed-response"]["message-body"], "not found")
    }
    %{endif~}
  }
  %{else}
  default_action {
    type = "FIXED-RESPONSE"
    fixed_response {
      status_code  = "404"
      content_type = "text/plain"
      message_body = "not found"
    }
  }
  %{endif~}
}

    %{endfor~}

    %{endfor~}

    %{for ecs_service_name, ecs_service_values in try(ecs_cluster_values.services, {})~}

module "ecs_service_label_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(ecs_service_name, "-", "_"), ".", "_")}" {

  source  = "cloudposse/label/null"
  version = "0.25.0"

  stage      = ""
  namespace  = ""
  name       = "$${local.env_short}-${ecs_service_name}-${ecs_region_k}"
  delimiter  = "-"
  attributes = ["service"]
}

locals {
  ecs_service_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(ecs_service_name, "-", "_"), ".", "_")}_subnet_ids = distinct(flatten([
    %{for subnet in try(ecs_service_values.network.subnets, [])~}
    jsondecode(var.vpcs_json).vpc_${ecs_region_k}_${ecs_service_values.network.vpc}.subnets_info.subnet_${ecs_region_k}_${ecs_service_values.network.vpc}_${subnet.name}.${subnet.kind}_subnet_ids,
    %{endfor~}
  ]))
}

locals {
  ecs_service_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(ecs_service_name, "-", "_"), ".", "_")}_lb_subnet_ids = distinct(flatten([
    %{if try(ecs_service_values["load-balancer-config"].subnets, "") != ""}
      %{for subnet in ecs_service_values["load-balancer-config"].subnets~}
    jsondecode(var.vpcs_json).vpc_${try(ecs_service_values["load-balancer-config"].region, ecs_region_k)}_${try(ecs_service_values["load-balancer-config"].vpc, ecs_service_values.network.vpc)}.subnets_info.subnet_${try(ecs_service_values["load-balancer-config"].region, ecs_region_k)}_${try(ecs_service_values["load-balancer-config"].vpc, ecs_service_values.network.vpc)}_${subnet.name}.${subnet.kind}_subnet_ids,
      %{endfor~}
    %{else~}
      %{for subnet in try(ecs_service_values.network.subnets, [])~}
        %{if subnet.kind == "public"}
    jsondecode(var.vpcs_json).vpc_${ecs_region_k}_${ecs_service_values.network.vpc}.subnets_info.subnet_${ecs_region_k}_${ecs_service_values.network.vpc}_${subnet.name}.${subnet.kind}_subnet_ids,
        %{endif~}
      %{endfor~}
    %{endif~}
  ]))
}

resource "aws_security_group" "ecs_service_sg_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(ecs_service_name, "-", "_"), ".", "_")}" {

  provider = aws.${ecs_region_k}

  %{if try(ecs_service_values["security-group"].name, "") != ""}
  name = "${chomp(ecs_service_values["security-group"].name)}"
  %{else}
  name = format("%s-%s-%s-sg", local.env_short, "${replace(ecs_service_name, "_", "-")}", "${replace(ecs_region_k, "_", "-")}")
  %{endif~}
  description = "${chomp(try(ecs_service_values["security-group"].description, "Security group for ${ecs_service_name} service"))}"
  vpc_id      = jsondecode(var.vpcs_json).vpc_${ecs_region_k}_${ecs_service_values.network.vpc}.vpc_info.vpc_id

  revoke_rules_on_delete = true

  dynamic "ingress" {
    for_each = try(ecs_service_values["security-group"].ingress, [])
    content {
      description      = try(ingress.value.description, "")
      from_port        = ingress.value["from-port"]
      to_port          = ingress.value["to-port"]
      protocol         = ingress.value.protocol
      cidr_blocks      = try(ingress.value["cidr-blocks"], [])
      ipv6_cidr_blocks = try(ingress.value["ipv6-cidr-blocks"], [])
      security_groups  = try(ingress.value["security-groups"], [])
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = merge({
    Name        = module.ecs_service_label_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(ecs_service_name, "-", "_"), ".", "_")}.id
    Environment = local.environment
    Project     = local.project
  }, try(ecs_service_values["security-group"].tags, {}))
}

  %{if try(ecs_service_values.task["log-group"], "") != ""}

resource "aws_cloudwatch_log_group" "ecs_service_log_group_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(ecs_service_name, "-", "_"), ".", "_")}" {
  provider = aws.${ecs_region_k}

  name              = "${ecs_service_values.task["log-group"].name}"
  retention_in_days = ${try(ecs_service_values.task["log-group"]["retention-in-days"], 30)}

  tags = {
    Environment = local.environment
    Project     = local.project
  }
}

  %{endif~}

resource "aws_iam_role" "ecs_task_execution_role_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(ecs_service_name, "-", "_"), ".", "_")}" {

  name = format("%s-%s-%s-execution", local.env_short, "${replace(ecs_cluster_name, "-", "_")}", "${replace(ecs_service_name, "-", "_")}")

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role" "ecs_task_role_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(ecs_service_name, "-", "_"), ".", "_")}" {

  name = format("%s-%s-%s-task", local.env_short, "${replace(ecs_cluster_name, "-", "_")}", "${replace(ecs_service_name, "-", "_")}")

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution_role_policies_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(ecs_service_name, "-", "_"), ".", "_")}" {
  for_each = toset(try(ecs_service_values.task["execution-role-policy-arns"], []))

  role       = aws_iam_role.ecs_task_execution_role_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(ecs_service_name, "-", "_"), ".", "_")}.name
  policy_arn = each.value
}

resource "aws_iam_role_policy_attachment" "ecs_task_role_policies_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(ecs_service_name, "-", "_"), ".", "_")}" {
  for_each = toset(try(ecs_service_values.task["task-role-policy-arns"], []))

  role       = aws_iam_role.ecs_task_role_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(ecs_service_name, "-", "_"), ".", "_")}.name
  policy_arn = each.value
}

locals {
  ecs_service_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(ecs_service_name, "-", "_"), ".", "_")}_container_definitions = [
    %{for container_name, container_values in try(ecs_service_values.task.containers, {})~}
    {
      name      = "${container_name}"
      image     = "${container_values.image}"
      essential = ${try(container_values.essential, true)}
      cpu       = ${try(container_values.cpu, 0)}
      memory    = ${try(container_values.memory, 0)}
      portMappings = [
        %{for mapping in try(container_values["port-mappings"], [])~}
        {
          containerPort = ${mapping["container-port"]}
          hostPort      = ${try(mapping["host-port"], mapping["container-port"])}
          protocol      = upper("${try(mapping.protocol, "tcp")}")
        },
        %{endfor~}
      ]
      environment = [
        %{for env_name, env_value in try(container_values.environment, {})~}
        {
          name  = "${env_name}"
          value = "${env_value}"
        },
        %{endfor~}
      ]
      %{if try(container_values["log-configuration"], "") != ""}
      logConfiguration = {
        logDriver = "${container_values["log-configuration"]["log-driver"]}"
        options = {
          %{for opt_name, opt_value in try(container_values["log-configuration"].options, {})~}
          "${opt_name}" = "${opt_value}"
          %{endfor~}
        }
      }
      %{endif~}
    },
    %{endfor~}
  ]
}

  %{if try(ecs_service_values["load-balancer-config"], "") != ""}

    %{if try(ecs_service_values["load-balancer-config"].shared, null) == null}

      %{if try(ecs_service_values["load-balancer-config"].type, "alb") == "alb"}

resource "aws_security_group" "ecs_service_lb_sg_${replace(replace(replace(ecs_region_k, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(ecs_cluster_name, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(ecs_service_name, "-", "_"), ".", "_"), " ", "_")}" {

  provider = aws.${ecs_region_k}

  name        = format("%s-%s-lb", local.env_short, "${replace(ecs_service_name, "-", "_")}")
  description = "Security group for ${ecs_service_name} load balancer"
  vpc_id      = jsondecode(var.vpcs_json).vpc_${ecs_region_k}_${ecs_service_values.network.vpc}.vpc_info.vpc_id

  dynamic "ingress" {
    for_each = try(ecs_service_values["load-balancer-config"]["security-group"].ingress, try(ecs_service_values["security-group"].ingress, []))
    content {
      description      = try(ingress.value.description, "")
      from_port        = ingress.value["from-port"]
      to_port          = ingress.value["to-port"]
      protocol         = ingress.value.protocol
      cidr_blocks      = try(ingress.value["cidr-blocks"], [])
      ipv6_cidr_blocks = try(ingress.value["ipv6-cidr-blocks"], [])
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Environment = local.environment
    Project     = local.project
  }
}

      %{endif~}

resource "aws_lb" "ecs_service_lb_${replace(replace(replace(ecs_region_k, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(ecs_cluster_name, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(ecs_service_name, "-", "_"), ".", "_"), " ", "_")}" {

  provider = aws.${ecs_region_k}

  name               = substr(format("%s-%s-%s", local.env_short, "${replace(replace(ecs_service_name, "_", "-"), " ", "-")}", "${replace(replace(ecs_region_k, "_", "-"), " ", "-")}"), 0, 32)
  internal           = lower(chomp(try(ecs_service_values["load-balancer-config"].scheme, "internet-facing"))) == "internal"
  load_balancer_type = chomp(try(ecs_service_values["load-balancer-config"].type, "alb")) == "nlb" ? "network" : "application"

  subnets = local.ecs_service_${replace(replace(replace(ecs_region_k, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(ecs_cluster_name, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(ecs_service_name, "-", "_"), ".", "_"), " ", "_")}_lb_subnet_ids

  security_groups = chomp(try(ecs_service_values["load-balancer-config"].type, "alb")) == "alb" ? [aws_security_group.ecs_service_lb_sg_${replace(replace(replace(ecs_region_k, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(ecs_cluster_name, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(ecs_service_name, "-", "_"), ".", "_"), " ", "_")}.id] : null

  enable_cross_zone_load_balancing = chomp(try(ecs_service_values["load-balancer-config"].type, "alb")) == "nlb" ? try(ecs_service_values["load-balancer-config"]["enable-cross-zone-load-balancing"], true) : null

  tags = merge({
    Environment = local.environment
    Project     = local.project
  }, try(ecs_service_values["load-balancer-config"].tags, {}))
}

    %{endif~}

resource "aws_lb_target_group" "ecs_service_target_group_${replace(replace(replace(ecs_region_k, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(ecs_cluster_name, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(ecs_service_name, "-", "_"), ".", "_"), " ", "_")}" {
  for_each = try(ecs_service_values["load-balancer-config"].listeners, {})

  provider = aws.${ecs_region_k}

  name = substr(format("%s-%s-%s-%s", local.env_short, replace(replace("${ecs_service_name}", "_", "-"), " ", "-"), replace(each.key, "_", "-"), "tg"), 0, 32)
  port        = each.value["target-port"]
  protocol    = upper(each.value["target-protocol"])
  target_type = "ip"
  vpc_id      = jsondecode(var.vpcs_json).vpc_${ecs_region_k}_${ecs_service_values.network.vpc}.vpc_info.vpc_id

  health_check {
    port                = try(each.value["health-check"].port, each.value["target-port"])
    protocol            = upper(try(each.value["health-check"].protocol, each.value["target-protocol"]))
    interval            = try(each.value["health-check"].interval, null)
    healthy_threshold   = try(each.value["health-check"].healthy_threshold, null)
    unhealthy_threshold = try(each.value["health-check"].unhealthy_threshold, null)
    %{if try(each.value["health-check"].path, "") != ""}
    path                = "${each.value["health-check"].path}"
    matcher             = "${try(each.value["health-check"].matcher, "200-499")}"
    %{endif~}
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Environment = local.environment
    Project     = local.project
  }
}

    %{if try(ecs_service_values["load-balancer-config"].shared, null) == null}

resource "aws_lb_listener" "ecs_service_listener_${replace(replace(replace(ecs_region_k, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(ecs_cluster_name, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(ecs_service_name, "-", "_"), ".", "_"), " ", "_")}" {
  for_each = try(ecs_service_values["load-balancer-config"].listeners, {})

  provider = aws.${ecs_region_k}

  load_balancer_arn = aws_lb.ecs_service_lb_${replace(replace(replace(ecs_region_k, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(ecs_cluster_name, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(ecs_service_name, "-", "_"), ".", "_"), " ", "_")}.arn
  port              = each.value["listener-port"]
  protocol          = upper(each.value["listener-protocol"])
  ssl_policy        = upper(each.value["listener-protocol"]) == "HTTPS" ? try(ecs_service_values["load-balancer-config"]["ssl-policy"], "ELBSecurityPolicy-2016-08") : null
  certificate_arn   = upper(each.value["listener-protocol"]) == "HTTPS" ? (
    length(trimspace(try(ecs_service_values["load-balancer-config"]["certificate-arn"], ""))) > 0 ? trimspace(try(ecs_service_values["load-balancer-config"]["certificate-arn"], "")) : null
  ) : null

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ecs_service_target_group_${replace(replace(replace(ecs_region_k, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(ecs_cluster_name, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(ecs_service_name, "-", "_"), ".", "_"), " ", "_")}[each.key].arn
  }
}

    %{else}

resource "aws_lb_listener_rule" "ecs_service_listener_rule_${replace(replace(replace(ecs_region_k, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(ecs_cluster_name, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(ecs_service_name, "-", "_"), ".", "_"), " ", "_")}" {
  provider = aws.${ecs_region_k}

  for_each = {
    for rule in try(ecs_service_values["load-balancer-config"].shared.rules, []) :
    format("%03d", rule.priority) => rule
  }

  listener_arn = aws_lb_listener.ecs_cluster_lb_listener_${replace(replace(replace(ecs_region_k, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(ecs_cluster_name, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(try(ecs_service_values["load-balancer-config"].shared["load-balancer"], ""), "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(try(ecs_service_values["load-balancer-config"].shared.listener, ""), "-", "_"), ".", "_"), " ", "_")}.arn
  priority     = each.value.priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ecs_service_target_group_${replace(replace(replace(ecs_region_k, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(ecs_cluster_name, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(ecs_service_name, "-", "_"), ".", "_"), " ", "_")}[try(ecs_service_values["load-balancer-config"].shared.listener, "default")].arn
  }

  dynamic "condition" {
    for_each = try(each.value["conditions"]["path-patterns"], [])
    content {
      path_pattern {
        values = [condition.value]
      }
    }
  }

  dynamic "condition" {
    for_each = try(each.value["conditions"]["host-headers"], [])
    content {
      host_header {
        values = [condition.value]
      }
    }
  }

  dynamic "condition" {
    for_each = try(each.value["conditions"]["source-ips"], [])
    content {
      source_ip {
        values = [condition.value]
      }
    }
  }
}

    %{endif~}

  %{endif~}

resource "aws_ecs_task_definition" "ecs_task_definition_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(ecs_service_name, "-", "_"), ".", "_")}" {

  %{if try(ecs_service_values.task.family, "") != ""}
  family = "${chomp(ecs_service_values.task.family)}"
  %{else}
  family = module.ecs_service_label_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(ecs_service_name, "-", "_"), ".", "_")}.id
  %{endif~}
  cpu                      = tostring(${try(ecs_service_values.task.cpu, 1024)})
  memory                   = tostring(${try(ecs_service_values.task.memory, 2048)})
  network_mode             = "${chomp(try(ecs_service_values.task["network-mode"], "awsvpc"))}"
  requires_compatibilities = [
    %{for compatibility in try(ecs_service_values.task["requires-compatibilities"], ["FARGATE"])~}
    "${compatibility}",
    %{endfor~}
  ]
  execution_role_arn       = aws_iam_role.ecs_task_execution_role_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(ecs_service_name, "-", "_"), ".", "_")}.arn
  task_role_arn            = aws_iam_role.ecs_task_role_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(ecs_service_name, "-", "_"), ".", "_")}.arn

  container_definitions = jsonencode(local.ecs_service_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(ecs_service_name, "-", "_"), ".", "_")}_container_definitions)

  dynamic "volume" {
    for_each = try(ecs_service_values.task.volumes, {})
    content {
      name = volume.key
      %{if try(volume.value["efs-volume-configuration"], "") != ""}
      efs_volume_configuration {
        file_system_id          = volume.value["efs-volume-configuration"]["file-system-id"]
        root_directory          = try(volume.value["efs-volume-configuration"]["root-directory"], "/")
        transit_encryption      = try(volume.value["efs-volume-configuration"]["transit-encryption"], "ENABLED")
        transit_encryption_port = try(volume.value["efs-volume-configuration"]["transit-encryption-port"], null)
        authorization_config {
          access_point_id = try(volume.value["efs-volume-configuration"]["authorization-config"]["access-point-id"], null)
          iam             = try(volume.value["efs-volume-configuration"]["authorization-config"]["iam"], null)
        }
      }
      %{endif~}
    }
  }

  tags = {
    Environment = local.environment
    Project     = local.project
  }
}

resource "aws_ecs_service" "ecs_service_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(ecs_service_name, "-", "_"), ".", "_")}" {

  provider = aws.${ecs_region_k}

  %{if try(ecs_service_values.service.name, "") != ""}
  name = "${chomp(ecs_service_values.service.name)}"
  %{else}
  name = module.ecs_service_label_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(ecs_service_name, "-", "_"), ".", "_")}.id
  %{endif~}
  cluster         = aws_ecs_cluster.ecs_cluster_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}.arn
  desired_count   = ${try(ecs_service_values.service["desired-count"], 1)}
  launch_type     = "${chomp(try(ecs_service_values.service["launch-type"], "FARGATE"))}"
  platform_version = "${chomp(try(ecs_service_values.service["platform-version"], "1.4.0"))}"

  deployment_controller {
    type = upper("${try(ecs_service_values.service["deployment-controller"], "ECS")}")
  }

  deployment_minimum_healthy_percent = ${try(ecs_service_values.service["min-healthy-percent"], 50)}
  deployment_maximum_percent         = ${try(ecs_service_values.service["max-percent"], 200)}
  enable_execute_command             = ${try(ecs_service_values.service["enable-execute-command"], false)}

  network_configuration {
    assign_public_ip = ${try(ecs_service_values.service["assign-public-ip"], true)}
    subnets          = local.ecs_service_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(ecs_service_name, "-", "_"), ".", "_")}_subnet_ids
    security_groups  = [
      aws_security_group.ecs_service_sg_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(ecs_service_name, "-", "_"), ".", "_")}.id
    ]
  }

  task_definition = aws_ecs_task_definition.ecs_task_definition_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(ecs_service_name, "-", "_"), ".", "_")}.arn

  dynamic "capacity_provider_strategy" {
    for_each = try(ecs_service_values.service["capacity-provider-strategy"], [])
    content {
      capacity_provider = capacity_provider_strategy.value["capacity-provider"]
      weight            = try(capacity_provider_strategy.value.weight, null)
      base              = try(capacity_provider_strategy.value.base, null)
    }
  }

  dynamic "load_balancer" {
    for_each = try(ecs_service_values["load-balancer-config"].listeners, {})
    content {
      target_group_arn = aws_lb_target_group.ecs_service_target_group_${replace(replace(replace(ecs_region_k, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(ecs_cluster_name, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(ecs_service_name, "-", "_"), ".", "_"), " ", "_")}[load_balancer.key].arn
      container_name   = load_balancer.value["container-name"]
      container_port   = load_balancer.value["container-port"]
    }
  }

  %{if try(ecs_service_values["load-balancer-config"].shared, null) == null}
  depends_on = [
    %{for listener_name, listener_values in try(ecs_service_values["load-balancer-config"].listeners, {})~}
    aws_lb_listener.ecs_service_listener_${replace(replace(replace(ecs_region_k, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(ecs_cluster_name, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(ecs_service_name, "-", "_"), ".", "_"), " ", "_")}[ "${listener_name}" ],
    %{endfor~}
  ]
  %{else}
  depends_on = [
    %{for rule in try(ecs_service_values["load-balancer-config"].shared.rules, [])~}
    aws_lb_listener_rule.ecs_service_listener_rule_${replace(replace(replace(ecs_region_k, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(ecs_cluster_name, "-", "_"), ".", "_"), " ", "_")}_${replace(replace(replace(ecs_service_name, "-", "_"), ".", "_"), " ", "_")}[ "${format("%03d", rule.priority)}" ],
    %{endfor~}
  ]
  %{endif~}

  tags = merge({
    Environment = local.environment
    Project     = local.project
  }, try(ecs_service_values.service.tags, {}))
}

    %{endfor~}

  %{endfor~}

%{endfor~}
EOF
}

generate "dynamic-ecs-outputs" {
  path      = "dynamic-ecs-outputs.tf"
  if_exists = "overwrite"
  contents  = <<EOF

output ecs_clusters {

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

output ecs_services {

    value = merge(

%{for ecs_region_k, ecs_region_v in try(local.config.ecs.regions, {})~}

  %{for ecs_cluster_name, ecs_cluster_values in ecs_region_v~}

    %{for ecs_service_name, ecs_service_values in try(ecs_cluster_values.services, {})~}
      {
        "ecs_service_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(ecs_service_name, "-", "_"), ".", "_")}" = {
          "service_arn"  = aws_ecs_service.ecs_service_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(ecs_service_name, "-", "_"), ".", "_")}.arn
          "service_name" = aws_ecs_service.ecs_service_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(ecs_service_name, "-", "_"), ".", "_")}.name
          "cluster_arn"  = aws_ecs_service.ecs_service_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(ecs_service_name, "-", "_"), ".", "_")}.cluster
          "desired_count" = aws_ecs_service.ecs_service_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(ecs_service_name, "-", "_"), ".", "_")}.desired_count
        }
      },
    %{endfor~}

  %{endfor~}

%{endfor~}
   )
}

output ecs_load_balancers {

    value = merge(

%{for ecs_region_k, ecs_region_v in try(local.config.ecs.regions, {})~}

  %{for ecs_cluster_name, ecs_cluster_values in ecs_region_v~}

    %{for ecs_service_name, ecs_service_values in try(ecs_cluster_values.services, {})~}
      %{if try(ecs_service_values["load-balancer-config"], "") != ""}
      {
        "ecs_lb_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(ecs_service_name, "-", "_"), ".", "_")}" = {
          "arn"      = aws_lb.ecs_service_lb_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(ecs_service_name, "-", "_"), ".", "_")}.arn
          "dns_name" = aws_lb.ecs_service_lb_${replace(replace(ecs_region_k, "-", "_"), ".", "_")}_${replace(replace(ecs_cluster_name, "-", "_"), ".", "_")}_${replace(replace(ecs_service_name, "-", "_"), ".", "_")}.dns_name
        }
      },
      %{endif~}
    %{endfor~}

  %{endfor~}

%{endfor~}
   )
}

EOF
}

terraform {

  source = ".//."

  before_hook "terraform_fmt" {
    commands = ["apply", "plan", "destroy"]
    execute  = ["terraform", "fmt", "-recursive"]
  }

}
