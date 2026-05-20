terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
  backend "gcs" {
    prefix = "terraform/gpu-state"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

resource "google_container_node_pool" "gpu" {
  name     = "gpu-pool"
  cluster  = var.cluster_name
  location = var.cluster_zone

  node_count = 1

  node_config {
    machine_type = var.gpu_machine_type
    disk_size_gb = 50
    disk_type    = "pd-standard"

    guest_accelerator {
      type  = var.gpu_type
      count = 1
    }

    spot         = var.spot
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }
}
