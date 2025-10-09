output "eks_clusters" {
  value = jsondecode(var.eks_clusters_json)
}

output "eks_node_groups" {
  value = jsondecode(var.eks_node_groups_json)
}

output "ecs_clusters" {
  value = jsondecode(var.ecs_clusters_json)
}

output "ecs_services" {
  value = jsondecode(var.ecs_services_json)
}

output "ecs_load_balancers" {
  value = jsondecode(var.ecs_load_balancers_json)
}
