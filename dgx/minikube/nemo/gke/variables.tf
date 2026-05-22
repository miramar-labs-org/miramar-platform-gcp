variable "project_id" { type = string }

# Pick a zone where A2 Ultra capacity exists (varies by region/zone).
variable "zone" { type = string default = "us-central1-a" }

variable "cluster_name" { type = string default = "nemo-a2ultra" }

# Cheapest NeMo-compatible: 2 × A100 80GB on a single node.
# A2 Ultra machine family provides A100 80GB. 
variable "machine_type" { type = string default = "a2-ultragpu-2g" }

# Cheapest compute: Spot nodes (interruptible). Turn off for stability.
variable "use_spot" { type = bool default = true }

# NeMo tutorial mentions needing lots of free disk (>=200GB). 
variable "disk_size_gb" { type = number default = 500 }

# Basic VPC config
variable "network_name"   { type = string default = "nemo-net" }
variable "subnet_name"    { type = string default = "nemo-subnet" }
variable "subnet_cidr"    { type = string default = "10.10.0.0/16" }
variable "pods_range"     { type = string default = "10.20.0.0/16" }
variable "services_range" { type = string default = "10.30.0.0/20" }
