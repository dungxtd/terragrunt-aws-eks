# CORRECT DEPENDENCY ORDER for all environments
# Creation: VPC → EKS cluster → node groups → EKS addons → load balancers → workloads
# Destroy: workloads → load balancers → EKS addons → node groups → EKS cluster → VPC
dependencies {
  paths = [
    "../../tg-modules//tfstate",
    "../../tg-modules//vpc",
    "../../tg-modules//eks",
    "../../tg-modules//eks-addons",
    "../../tg-modules//eks-lb",
    "../../tg-modules//eks-helm-bootstrap",
    "../../tg-modules//kms"
  ]
}

dependency "eks" {
  config_path = "../../tg-modules//eks"
  skip_outputs = false
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "destroy"]
  mock_outputs = {
    eks_clusters = {}
    eks_node_groups = {}
    eks_node_groups_sg = {}
  }
}

inputs = {

  eks_clusters_json = dependency.eks.outputs.eks_clusters
  eks_node_groups_json = dependency.eks.outputs.eks_node_groups
  eks_node_groups_sg_json = dependency.eks.outputs.eks_node_groups_sg

}
