provider "google" {
  project = var.project_id
  zone    = var.zone
}

# Enable required APIs
resource "google_project_service" "services" {
  for_each = toset([
    "compute.googleapis.com",
    "container.googleapis.com",
    "iam.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

# Network (VPC-native / alias IPs)
resource "google_compute_network" "vpc" {
  name                    = var.network_name
  auto_create_subnetworks = false
  depends_on              = [google_project_service.services]
}

# Subnet must be regional even if cluster is zonal
resource "google_compute_subnetwork" "subnet" {
  name          = var.subnet_name
  region        = regex("^([a-z]+-[a-z0-9]+)[-][a-z]$", var.zone)[0]
  network       = google_compute_network.vpc.id
  ip_cidr_range = var.subnet_cidr

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_range
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_range
  }
}

# Service account for nodes
resource "google_service_account" "gke_nodes" {
  account_id   = "${var.cluster_name}-nodes"
  display_name = "GKE nodes for ${var.cluster_name}"
}

resource "google_project_iam_member" "node_sa_roles" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/storage.objectViewer",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

# Zonal GKE Standard cluster
resource "google_container_cluster" "cluster" {
  name     = var.cluster_name
  location = var.zone

  network    = google_compute_network.vpc.name
  subnetwork = google_compute_subnetwork.subnet.name

  remove_default_node_pool = true
  initial_node_count       = 1

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  release_channel {
    channel = "REGULAR"
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  depends_on = [google_project_service.services]
}

# Single node pool: 1 node, machine type a2-ultragpu-2g (2×A100 80GB)
resource "google_container_node_pool" "gpu_pool" {
  name     = "${var.cluster_name}-gpu"
  cluster  = google_container_cluster.cluster.name
  location = var.zone

  node_count = 1

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    service_account = google_service_account.gke_nodes.email

    # Cheapest option: Spot
    spot = var.use_spot

    image_type   = "COS_CONTAINERD"
    machine_type = var.machine_type
    disk_type    = "pd-ssd"
    disk_size_gb = var.disk_size_gb

    oauth_scopes = [
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
      "https://www.googleapis.com/auth/devstorage.read_only",
    ]

    labels = {
      workload = "nemo"
      gpu      = "a100-80gb-x2"
    }

    # Keep non-NeMo workloads off this expensive node.
    taint {
      key    = "nemo"
      value  = "reserved"
      effect = "NO_SCHEDULE"
    }

    metadata = {
      disable-legacy-endpoints = "true"
    }
  }

  depends_on = [
    google_project_iam_member.node_sa_roles
  ]
}
