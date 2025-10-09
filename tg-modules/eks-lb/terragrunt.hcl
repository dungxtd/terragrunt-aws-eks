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
    "../../tg-modules//eks",
    "../../tg-modules//vpc"
  ]
}

dependency "eks" {
  config_path                             = "../../tg-modules//eks"
  skip_outputs                            = false
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "destroy"]
  mock_outputs = {
    eks_clusters       = {}
    eks_node_groups    = {}
    eks_node_groups_sg = {}
  }
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

  eks_clusters_json       = dependency.eks.outputs.eks_clusters
  eks_node_groups_json    = dependency.eks.outputs.eks_node_groups
  eks_node_groups_sg_json = dependency.eks.outputs.eks_node_groups_sg
  vpcs_json               = dependency.vpc.outputs.vpcs



}

generate "dynamic-lb-modules" {
  path      = "dynamic-lb-modules.tf"
  if_exists = "overwrite"
  contents  = <<EOF

locals {

  main_app_hostname = "${chomp(try(local.config.network.route53.main-app-hostname, "${local.config.general.env-short}.${local.config.general.project}"))}"

  uuid_domain_names = {

%{for eks_region_k, eks_region_v in try(local.config.eks.regions, {})~}

  %{for eks_name, eks_values in eks_region_v~}
    
    "${local.config.general.env-short}.${eks_name}.${eks_region_k}" = substr(uuidv5("dns","${local.config.general.env-short}.${eks_region_k}.${eks_name}"), 0, 31)

  %{endfor~}

%{endfor~}

  }

}

%{for eks_region_k, eks_region_v in try(local.config.eks.regions, {})~}

  %{for eks_name, eks_values in eks_region_v~}

    %{if try(eks_values.use-route53, false)}

module "acm_request_certificate_${eks_region_k}_${eks_name}" {

  providers = {
    aws = aws.${eks_region_k}
  }

  source = "cloudposse/acm-request-certificate/aws"
  version = "0.16.3"
  zone_name                         = "${chomp(try(local.config.network.route53.zones.default.tld, "cluster.local"))}"
  domain_name                       = substr(format("%s.%s", "$${local.uuid_domain_names["${local.config.general.env-short}.${eks_name}.${eks_region_k}"]}", "${local.config.network.route53.zones.default.tld}"), -64, -1)
  process_domain_validation_options = true
  ttl                               = "60"
  subject_alternative_names         = distinct([
    "$${local.main_app_hostname}.${local.config.network.route53.zones.default.tld}",
    "*.$${local.main_app_hostname}.${local.config.network.route53.zones.default.tld}",

    "${local.config.general.env-short}.${eks_name}.${local.config.network.route53.zones.default.tld}",
    "*.${local.config.general.env-short}.${eks_name}.${local.config.network.route53.zones.default.tld}",

    "${local.config.general.env-short}.${eks_name}.global.${local.config.network.route53.zones.default.tld}",
    "*.${local.config.general.env-short}.${eks_name}.global.${local.config.network.route53.zones.default.tld}",

    "${local.config.general.env-short}.${eks_name}.${eks_region_k}.${local.config.network.route53.zones.default.tld}",
    "*.${local.config.general.env-short}.${eks_name}.${eks_region_k}.${local.config.network.route53.zones.default.tld}"
%{for alb_hostname in try(local.config.network.alb.acm.extra-fqdn, {})~}
    , "${alb_hostname}"
%{endfor~}
  ])
}

    %{endif~}

    %{for deployment_type in try(eks_values.deployment-types, [try(eks_values.deployment-type, "alb")])~}

module "lb_${eks_region_k}_${eks_name}_${deployment_type}" {

  providers = {
    aws = aws.${eks_region_k}
  }

  source = "./tf-module"

  cluster_name              = split(":", jsondecode(var.eks_clusters_json).eks_cluster_${eks_region_k}_${eks_name}.eks_info.eks_cluster_id)[0]
  load_balancer_type        = "${deployment_type}" == "alb" ? "application" : "${deployment_type}" == "nlb" ? "network" : "application"

  subnet_ids_list = concat(
  %{for subnet in eks_values.network.subnets~}
    %{if subnet.kind == "public"}
  jsondecode(var.vpcs_json).vpc_${eks_region_k}_${eks_values.network.vpc}.subnets_info.subnet_${eks_region_k}_${eks_values.network.vpc}_${subnet.name}.${subnet.kind}_subnet_ids,
    %{endif~}
  %{endfor~}
  )

  vpcid                     = jsondecode(var.vpcs_json).vpc_${eks_region_k}_${eks_values.network.vpc}.vpc_info.vpc_id
  autoscale_group_names     = toset( [
    %{for eng_name, eng_values in eks_values.node-groups~}
      %{if try(eng_values.exposed-ports, "") != ""}
    flatten(jsondecode(var.eks_node_groups_json).eks_node_group_${eks_region_k}_${eks_name}_${eng_name}.eng_info.eks_node_group_resources[*][*].autoscaling_groups[*].name)[0],
      %{endif~}
    %{endfor~}
  ] )
  cluster_security_group_ids = toset( [
    %{for eng_name, eng_values in eks_values.node-groups~}
      %{if try(eng_values.exposed-ports, "") != ""}
    jsondecode(var.eks_node_groups_sg_json).eks_node_group_sg_${eks_region_k}_${eks_name}_${eng_name}.eng_sg_info.id,
      %{endif~}
    %{endfor~}
  ] )

  tags                      = {}
  internal                  = false

  # Dynamic configuration based on deployment type
  alb_listeners = "${deployment_type}" == "alb" ? {
    "default" = {
      listener_port     = ${try(eks_values.load-balancer-config.alb.listener-port, 80)}
      listener_protocol = "${try(eks_values.load-balancer-config.alb.listener-protocol, "HTTP")}"
      target_port       = ${try(eks_values.load-balancer-config.alb.target-port, 30080)}
      target_protocol   = "${try(eks_values.load-balancer-config.alb.target-protocol, "HTTP")}"
      health_check = {
        path     = "${try(eks_values.load-balancer-config.alb.health-check.path, "/")}"
        port     = ${try(eks_values.load-balancer-config.alb.health-check.port, 30080)}
        protocol = "${try(eks_values.load-balancer-config.alb.health-check.protocol, "HTTP")}"
        matcher  = "${try(eks_values.load-balancer-config.alb.health-check.matcher, "200-499")}"
      }
    }
  } : {}

  nlb_target_groups = "${deployment_type}" == "nlb" ? {
    %{if try(eks_values.load-balancer-config.nlb.listeners, null) != null~}
      %{for listener_name, listener_config in eks_values.load-balancer-config.nlb.listeners~}
    "${listener_name}" = {
      listener_port     = ${listener_config.listener-port}
      listener_protocol = "${listener_config.listener-protocol}"
      target_port       = ${listener_config.target-port}
      target_protocol   = "${listener_config.target-protocol}"
      health_check = {
        port                = ${listener_config.health-check.port}
        protocol            = "${listener_config.health-check.protocol}"
        interval            = ${try(listener_config.health-check.interval, 30)}
        healthy_threshold   = ${try(listener_config.health-check.healthy_threshold, 3)}
        unhealthy_threshold = ${try(listener_config.health-check.unhealthy_threshold, 3)}
        %{if try(listener_config.health-check.path, null) != null~}
        path                = "${listener_config.health-check.path}"
        %{endif~}
      }
    }
      %{endfor~}
    %{else~}
    "default" = {
      listener_port     = ${try(eks_values.load-balancer-config.nlb.listener-port, 1935)}
      listener_protocol = "${try(eks_values.load-balancer-config.nlb.listener-protocol, "TCP")}"
      target_port       = ${try(eks_values.load-balancer-config.nlb.target-port, 31935)}
      target_protocol   = "${try(eks_values.load-balancer-config.nlb.target-protocol, "TCP")}"
      health_check = {
        port                = ${try(eks_values.load-balancer-config.nlb.health-check.port, 31935)}
        protocol            = "${try(eks_values.load-balancer-config.nlb.health-check.protocol, "TCP")}"
        interval            = ${try(eks_values.load-balancer-config.nlb.health-check.interval, 30)}
        healthy_threshold   = ${try(eks_values.load-balancer-config.nlb.health-check.healthy_threshold, 3)}
        unhealthy_threshold = ${try(eks_values.load-balancer-config.nlb.health-check.unhealthy_threshold, 3)}
      }
    }
    %{endif~}
  } : {}

  # Cross zone load balancing for NLB
  enable_cross_zone_load_balancing = "${deployment_type}" == "nlb" ? ${try(eks_values.cross_zone_load_balancing, true)} : false



}

    %{endfor~}

  %{endfor~}

%{endfor~}
EOF
}

generate "dynamic-outputs" {
  path      = "dynamic-eks-outputs.tf"
  if_exists = "overwrite"
  contents  = <<EOF

output eks_load_balancers {

    value = merge(

%{for eks_region_k, eks_region_v in try(local.config.eks.regions, {})~}

  %{for eks_name, eks_values in eks_region_v~}
    %{for deployment_type in try(eks_values.deployment-types, [try(eks_values.deployment-type, "alb")])~}
      {
        "eks_${deployment_type}_${eks_region_k}_${eks_name}" = {
          "${deployment_type}_info" = module.lb_${eks_region_k}_${eks_name}_${deployment_type}
        }
      },
    %{endfor~}

  %{endfor~}

%{endfor~}
   )
}

# Keep ALB output for backward compatibility
output eks_albs {

    value = merge(

%{for eks_region_k, eks_region_v in try(local.config.eks.regions, {})~}

  %{for eks_name, eks_values in eks_region_v~}
    %{for deployment_type in try(eks_values.deployment-types, [try(eks_values.deployment-type, "alb")])~}
      %{if deployment_type == "alb"}
      {
        "eks_alb_${eks_region_k}_${eks_name}" = {
          "alb_info" = module.lb_${eks_region_k}_${eks_name}_${deployment_type}
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
