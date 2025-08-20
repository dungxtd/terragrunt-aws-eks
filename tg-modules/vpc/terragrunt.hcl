# configure terragrunt behaviours with these
locals {
  ENVIRONMENT_NAME = get_env("ENVIRONMENT_NAME", "development")
  config = yamldecode(file("../../environments/${ get_env("ENVIRONMENT_NAME", "development") }/config.yaml"))
  default_outputs = {}
}

include "tf_main_config" {
  path = find_in_parent_folders()
}

generate "dynamic-network-modules" {
  path      = "dynamic-vpc-modules.tf"
  if_exists = "overwrite"
  contents  = <<EOF

# Data sources for VPC endpoints
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

%{ for vpc_region_k, vpc_region_v in try(local.config.network.vpc.regions, { } ) ~}

  %{ for vpc_name, vpc_values in vpc_region_v ~}

module "vpc_${vpc_region_k}_${vpc_name}" {

  providers = {
    aws = aws.${vpc_region_k}
  }

  source = "${ chomp(try(local.config.network.vpc.vpc-module-source, "cloudposse/vpc/aws")) }"
  version = "${ chomp(try(local.config.network.vpc.vpc-module-version, "2.0.0")) }"
  namespace = ""
  stage     = ""
  name      = "${ chomp(try(local.config.general.env-short, "dev")) }-${vpc_name}"

  ipv4_primary_cidr_block = "${vpc_values.ipv4-cidr}"

  assign_generated_ipv6_cidr_block = true
}

    %{ for sn_name, sn_values in vpc_values.subnets ~}

module "subnet_${vpc_region_k}_${vpc_name}_${sn_name}" {

  providers = {
    aws = aws.${vpc_region_k}
  }

  source = "${ chomp(try(local.config.network.vpc.subnet-module-source, "cloudposse/dynamic-subnets/aws")) }"
  version = "${ chomp(try(local.config.network.vpc.subnet-module-version, "2.4.2")) }"
  vpc_id             = module.vpc_${vpc_region_k}_${vpc_name}.vpc_id
  igw_id             = [module.vpc_${vpc_region_k}_${vpc_name}.igw_id]
  namespace           = ""
  stage               = ""
  name                = "${ chomp(try(local.config.general.env-short, "dev")) }-${vpc_name}-${sn_name}"
  ipv4_cidr_block     = [ "${sn_values.ipv4-cidr}" ]
  private_subnets_enabled = ${sn_values.private_subnets_enabled}
  public_subnets_enabled = ${sn_values.public_subnets_enabled}
  public_route_table_enabled = ${sn_values.igw}
  private_route_table_enabled = ${sn_values.igw}
  ipv6_egress_only_igw_id = [module.vpc_${vpc_region_k}_${vpc_name}.igw_id]
  nat_gateway_enabled = ${sn_values.ngw}
  availability_zones  = [ %{ for az_name in sn_values.availability-zones ~} "${az_name}", %{ endfor ~} ]

  public_subnets_additional_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnets_additional_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

}

    %{ endfor ~}

# VPC Endpoints for private node image pulling
# ECR API endpoint
resource "aws_vpc_endpoint" "ecr_api_${vpc_region_k}_${vpc_name}" {
  provider = aws.${vpc_region_k}

  vpc_id              = module.vpc_${vpc_region_k}_${vpc_name}.vpc_id
  service_name        = "com.amazonaws.$${data.aws_region.current.name}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.subnet_${vpc_region_k}_${vpc_name}_default.private_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints_${vpc_region_k}_${vpc_name}.id]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = "*"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name = "${ chomp(try(local.config.general.env-short, "dev")) }-${vpc_name}-ecr-api"
    Environment = "${ chomp(try(local.config.general.environment, "development")) }"
    Project = "${ chomp(try(local.config.general.project, "terragrunt-aws")) }"
  }
}

# ECR DKR endpoint
resource "aws_vpc_endpoint" "ecr_dkr_${vpc_region_k}_${vpc_name}" {
  provider = aws.${vpc_region_k}

  vpc_id              = module.vpc_${vpc_region_k}_${vpc_name}.vpc_id
  service_name        = "com.amazonaws.$${data.aws_region.current.name}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.subnet_${vpc_region_k}_${vpc_name}_default.private_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints_${vpc_region_k}_${vpc_name}.id]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = "*"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name = "${ chomp(try(local.config.general.env-short, "dev")) }-${vpc_name}-ecr-dkr"
    Environment = "${ chomp(try(local.config.general.environment, "development")) }"
    Project = "${ chomp(try(local.config.general.project, "terragrunt-aws")) }"
  }
}

# S3 endpoint for ECR image layers
resource "aws_vpc_endpoint" "s3_${vpc_region_k}_${vpc_name}" {
  provider = aws.${vpc_region_k}

  vpc_id            = module.vpc_${vpc_region_k}_${vpc_name}.vpc_id
  service_name      = "com.amazonaws.$${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.subnet_${vpc_region_k}_${vpc_name}_default.private_route_table_ids

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = "*"
        Action = [
          "s3:GetObject",
          "s3:PutObject"
        ]
        Resource = [
          "arn:aws:s3:::prod-$${data.aws_region.current.name}-starport-layer-bucket/*"
        ]
      }
    ]
  })

  tags = {
    Name = "${ chomp(try(local.config.general.env-short, "dev")) }-${vpc_name}-s3"
    Environment = "${ chomp(try(local.config.general.environment, "development")) }"
    Project = "${ chomp(try(local.config.general.project, "terragrunt-aws")) }"
  }
}

# Security group for VPC endpoints
resource "aws_security_group" "vpc_endpoints_${vpc_region_k}_${vpc_name}" {
  provider = aws.${vpc_region_k}

  name_prefix = "${ chomp(try(local.config.general.env-short, "dev")) }-${vpc_name}-vpc-endpoints-"
  vpc_id      = module.vpc_${vpc_region_k}_${vpc_name}.vpc_id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [module.vpc_${vpc_region_k}_${vpc_name}.vpc_cidr_block]
  }

  egress {
    description = "All outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${ chomp(try(local.config.general.env-short, "dev")) }-${vpc_name}-vpc-endpoints"
    Environment = "${ chomp(try(local.config.general.environment, "development")) }"
    Project = "${ chomp(try(local.config.general.project, "terragrunt-aws")) }"
  }

  depends_on = [
    module.vpc_${vpc_region_k}_${vpc_name},
    module.subnet_${vpc_region_k}_${vpc_name}_default
  ]
}

  %{ endfor ~}

%{ endfor ~}
EOF
}


generate "dynamic-outputs" {
  path      = "dynamic-vpc-outputs.tf"
  if_exists = "overwrite"
  contents  = <<EOF

output vpcs {

    value = merge(

%{ for vpc_region_k, vpc_region_v in try(local.config.network.vpc.regions, { } ) ~}

  %{ for vpc_name, vpc_values in vpc_region_v ~}
      {
        for key, value in module.vpc_${vpc_region_k}_${vpc_name}[*]:
            "vpc_${vpc_region_k}_${vpc_name}" => { "vpc_info" = value, "subnets_info" = merge(
              %{ for sn_name, sn_values in vpc_values.subnets ~}
          
                { for key, value in module.subnet_${vpc_region_k}_${vpc_name}_${sn_name}[*]: "subnet_${vpc_region_k}_${vpc_name}_${sn_name}" => value },
        
              %{ endfor ~}
              
            )}
      },
  %{ endfor ~}

%{ endfor ~}
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
