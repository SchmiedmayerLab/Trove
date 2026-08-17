#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

resource "google_container_cluster" "primary" {
  provider = google-beta

  name     = var.cluster_name
  project  = var.project_id
  location = var.zone

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.gke.id

  # Remove default node pool, use a separately managed pool below.
  remove_default_node_pool = true
  initial_node_count       = 1

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  release_channel {
    channel = "REGULAR"
  }

  datapath_provider = "ADVANCED_DATAPATH"

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.authorized_networks
      content {
        display_name = cidr_blocks.value.display_name
        cidr_block   = cidr_blocks.value.cidr_block
      }
    }
  }

  deletion_protection = false # TODO: disabled for cluster recreation

  depends_on = [google_project_service.apis]
}

resource "google_container_node_pool" "primary" {
  name     = "${var.cluster_name}-pool"
  project  = var.project_id
  location = var.zone
  cluster  = google_container_cluster.primary.name

  node_count = 1

  node_config {
    machine_type = "e2-standard-4"
    disk_size_gb = 30
    disk_type    = "pd-balanced"

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}
