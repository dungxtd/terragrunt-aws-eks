locals {
  random_id          = substr(random_pet.this.id, 0, 8)
  lb_name_prefix     = substr(random_uuid.this.id, 0, 6)
  alb_name_prefix    = substr(random_uuid.this.id, 0, 6) # Keep for backward compatibility
  short_cluster_name = substr(var.cluster_name, 0, 22)
}
