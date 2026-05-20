variable "project_id" {
  type    = string
  default = "miramar-platform"
}

variable "region" {
  type    = string
  default = "us-west1"
}

variable "zone" {
  type    = string
  default = "us-west1-a"
}

variable "cluster_name" {
  type    = string
  default = "miramar-shared-gke"
}

variable "ar_repo" {
  type    = string
  default = "apps"
}

variable "node_pool_count" {
  type    = number
  default = 1
}
