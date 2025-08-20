# configure terragrunt behaviours with these
locals {
  ENVIRONMENT_NAME = get_env("ENVIRONMENT_NAME", "development")
  config = yamldecode(file("../../environments/${ get_env("ENVIRONMENT_NAME", "development") }/config.yaml"))
  default_outputs = {}
}

include "tf_main_config" {
  path = find_in_parent_folders()
}

dependencies {
  paths = [
    "../../tg-modules//vpc",
    "../../tg-modules//eks"
  ]
}

dependency "vpc" {
  config_path = "../../tg-modules//vpc"
  skip_outputs = false
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs = {
    vpcs = merge([
      for vpc_region_k, vpc_region_v in try(local.config.network.vpc.regions, {}) : {
        for vpc_name, vpc_values in vpc_region_v :
          "vpc_${vpc_region_k}_${vpc_name}" => {
            "vpc_info": { "vpc_id": "a1b2c3" },
            "subnets_info": merge([
              for sn_name, sn_values in vpc_values.subnets :
                { "subnet_${vpc_region_k}_${vpc_name}_${sn_name}" = { "public_subnet_ids": ["snid123"], "private_subnet_ids": ["snid123"] } }
            ]...)
          }
      }
    ]...)
  }
}

dependency "eks" {
  config_path = "../../tg-modules//eks"
  skip_outputs = false
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "destroy"]
  mock_outputs = {
    eks_clusters = {}
    eks_node_groups = {}
  }
}

inputs = {
  vpcs_json = jsonencode(try(dependency.vpc.outputs.vpcs, {}))
  eks_clusters_json = jsonencode(try(dependency.eks.outputs.eks_clusters, {}))
  eks_node_groups_json = jsonencode(try(dependency.eks.outputs.eks_node_groups, {}))
}

generate "dynamic-eks-addons" {
  path      = "dynamic-eks-addons.tf"
  if_exists = "overwrite"
  contents  = <<EOF

locals {
  environment = "${ chomp(try(local.config.general.environment, "development", local.ENVIRONMENT_NAME)) }"
  env_short   = "${ chomp(try(local.config.general.env-short, "dev")) }"
  project     = "${ chomp(try(local.config.general.project, "PROJECT_NAME")) }"
}

%{ for eks_region_k, eks_region_v in try(local.config.eks.regions, { } ) ~}

  %{ for eks_name, eks_values in eks_region_v ~}

# Managed EKS Add-ons with proper ordering and dependencies
# Order: vpc-cni → kube-proxy → coredns → ebs-csi-driver
# All addons depend on node groups being ready first

%{ if try(eks_values.addons, "") != "" }

# VPC CNI addon (must be first, but after node groups)
%{ if try(eks_values.addons.vpc-cni, "") != "" }
resource "aws_eks_addon" "vpc_cni_${eks_region_k}_${eks_name}" {
  provider = aws.${eks_region_k}
  
  cluster_name             = split(":", jsondecode(var.eks_clusters_json).eks_cluster_${eks_region_k}_${eks_name}.eks_info.eks_cluster_id)[0]
  addon_name               = "vpc-cni"
  addon_version            = "${eks_values.addons.vpc-cni.addon-version}"
  resolve_conflicts        = "${try(eks_values.addons.vpc-cni.resolve-conflicts, "OVERWRITE")}"
  service_account_role_arn = ${try(eks_values.addons.vpc-cni.service-account-role-arn, "null")}
  
  tags = {
    "Environment" = "$${local.environment}",
    "Project" = "$${local.project}"
  }
}
%{ endif ~}

# Kube-proxy addon (depends on vpc-cni)
%{ if try(eks_values.addons.kube-proxy, "") != "" }
resource "aws_eks_addon" "kube_proxy_${eks_region_k}_${eks_name}" {
  provider = aws.${eks_region_k}
  
  cluster_name             = split(":", jsondecode(var.eks_clusters_json).eks_cluster_${eks_region_k}_${eks_name}.eks_info.eks_cluster_id)[0]
  addon_name               = "kube-proxy"
  addon_version            = "${eks_values.addons.kube-proxy.addon-version}"
  resolve_conflicts        = "${try(eks_values.addons.kube-proxy.resolve-conflicts, "OVERWRITE")}"
  service_account_role_arn = ${try(eks_values.addons.kube-proxy.service-account-role-arn, "null")}
  
  depends_on = [
    %{ if try(eks_values.addons.vpc-cni, "") != "" }aws_eks_addon.vpc_cni_${eks_region_k}_${eks_name}%{ endif ~}
  ]
  
  tags = {
    "Environment" = "$${local.environment}",
    "Project" = "$${local.project}"
  }
}
%{ endif ~}

# CoreDNS addon (depends on kube-proxy)
%{ if try(eks_values.addons.coredns, "") != "" }
resource "aws_eks_addon" "coredns_${eks_region_k}_${eks_name}" {
  provider = aws.${eks_region_k}
  
  cluster_name             = split(":", jsondecode(var.eks_clusters_json).eks_cluster_${eks_region_k}_${eks_name}.eks_info.eks_cluster_id)[0]
  addon_name               = "coredns"
  addon_version            = "${eks_values.addons.coredns.addon-version}"
  resolve_conflicts        = "${try(eks_values.addons.coredns.resolve-conflicts, "OVERWRITE")}"
  service_account_role_arn = ${try(eks_values.addons.coredns.service-account-role-arn, "null")}
  
  depends_on = [
    %{ if try(eks_values.addons.vpc-cni, "") != "" }aws_eks_addon.vpc_cni_${eks_region_k}_${eks_name},%{ endif ~}
    %{ if try(eks_values.addons.kube-proxy, "") != "" }aws_eks_addon.kube_proxy_${eks_region_k}_${eks_name}%{ endif ~}
  ]
  
  tags = {
    "Environment" = "$${local.environment}",
    "Project" = "$${local.project}"
  }
}
%{ endif ~}

# EBS CSI Driver addon (optional, depends on coredns)
%{ if try(eks_values.addons.aws-ebs-csi-driver, "") != "" }
resource "aws_eks_addon" "ebs_csi_driver_${eks_region_k}_${eks_name}" {
  provider = aws.${eks_region_k}
  
  cluster_name             = split(":", jsondecode(var.eks_clusters_json).eks_cluster_${eks_region_k}_${eks_name}.eks_info.eks_cluster_id)[0]
  addon_name               = "aws-ebs-csi-driver"
  addon_version            = "${eks_values.addons.aws-ebs-csi-driver.addon-version}"
  resolve_conflicts        = "${try(eks_values.addons.aws-ebs-csi-driver.resolve-conflicts, "OVERWRITE")}"
  service_account_role_arn = ${try(eks_values.addons.aws-ebs-csi-driver.service-account-role-arn, "null")}
  
  depends_on = [
    %{ if try(eks_values.addons.coredns, "") != "" }aws_eks_addon.coredns_${eks_region_k}_${eks_name}%{ endif ~}
  ]
  
  tags = {
    "Environment" = "$${local.environment}",
    "Project" = "$${local.project}"
  }
}
%{ endif ~}

%{ endif ~}

  %{ endfor ~}

%{ endfor ~}
EOF
}

generate "variables" {
  path      = "variables.tf"
  if_exists = "overwrite"
  contents  = <<EOF
variable "vpcs_json" {
  description = "VPC configuration JSON"
  type        = string
}

variable "eks_clusters_json" {
  description = "EKS clusters configuration JSON"
  type        = string
}

variable "eks_node_groups_json" {
  description = "EKS node groups configuration JSON"
  type        = string
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
