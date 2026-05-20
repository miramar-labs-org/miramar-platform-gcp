output "cluster_name" {
  value = google_container_cluster.main.name
}

output "cluster_location" {
  value = google_container_cluster.main.location
}

output "node_pool_name" {
  value = google_container_node_pool.main.name
}

output "node_pool_count" {
  value = google_container_node_pool.main.node_count
}

output "ar_repository" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${var.ar_repo}"
}
