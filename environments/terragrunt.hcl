dependencies {
  paths = [
    "../../tg-modules//tfstate",
    "../../tg-modules//eks",
    "../../tg-modules//eks-helm-bootstrap",
    "../../tg-modules//eks-lb",
    "../../tg-modules//kms",
    "../../tg-modules//ecs",
  ]
}

dependency "eks" {
  config_path                             = "../../tg-modules//eks"
  skip_outputs                            = false
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "apply", "destroy"]
  mock_outputs = {
    eks_clusters       = {}
    eks_node_groups    = {}
    eks_node_groups_sg = {}
  }
}

dependency "ecs" {
  config_path                             = "../../tg-modules//ecs"
  skip_outputs                            = false
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "apply", "destroy"]
  mock_outputs = {
    ecs_clusters       = {}
    ecs_services       = {}
    ecs_load_balancers = {}
  }
}

inputs = {

  eks_clusters_json       = dependency.eks.outputs.eks_clusters
  eks_node_groups_json    = dependency.eks.outputs.eks_node_groups
  eks_node_groups_sg_json = dependency.eks.outputs.eks_node_groups_sg
  ecs_clusters_json       = dependency.ecs.outputs.ecs_clusters
  ecs_services_json       = dependency.ecs.outputs.ecs_services
  ecs_load_balancers_json = dependency.ecs.outputs.ecs_load_balancers

}
