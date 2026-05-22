output "cluster_name" { value = google_container_cluster.cluster.name }
output "zone"         { value = var.zone }
output "node_pool"    { value = google_container_node_pool.gpu_pool.name }
