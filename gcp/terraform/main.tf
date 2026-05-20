terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

resource "google_container_cluster" "main" {
  name     = var.cluster_name
  location = var.zone

  deletion_protection = false

  # Remove default node pool so we can configure our own
  remove_default_node_pool = true
  initial_node_count       = 1
}

resource "google_container_node_pool" "main" {
  name       = "e2-medium-pool"
  cluster    = google_container_cluster.main.name
  location   = var.zone
  node_count = 1

  node_config {
    machine_type = "e2-medium"
    disk_size_gb = 10
    disk_type    = "pd-standard"
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }
}
