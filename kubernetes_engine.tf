locals {
  node_pool_types = toset([
    "n1-standard-8",
    "n1-standard-16",
    "n1-standard-32",
  ])
  regional_node_pools = [
    for pair in setproduct(var.regions, local.node_pool_types) : {
      region       = pair[0]
      machine_type = pair[1]
    }
  ]
}

resource "google_project_service" "appsvc_container_api" {
  project                    = data.google_project.appsvc.project_id
  service                    = "container.googleapis.com"
  disable_dependent_services = true
}

resource "google_service_account" "gke_node" {
  project      = data.google_project.appsvc.project_id
  account_id   = "kubernetes-engine-node"
  display_name = "kubernetes-engine-node"

  provisioner "local-exec" {
    command = "sleep 10"
  }
}

resource "google_service_account_iam_member" "anthos_promsd_account" {
  service_account_id = google_service_account.gke_node.id
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:pan-${var.env}-appsvc.svc.id.goog[istio-system/promsd]"
  depends_on         = [google_container_cluster.appsvc]
}

resource "google_container_cluster" "appsvc" {
  provider                  = google-beta
  for_each                  = toset(var.regions)
  name                      = "cluster-${each.value}"
  project                   = data.google_project.appsvc.project_id
  location                  = each.value
  monitoring_service        = "monitoring.googleapis.com/kubernetes"
  logging_service           = "logging.googleapis.com/kubernetes"
  network                   = data.google_compute_network.internal.name
  subnetwork                = local.google_compute_subnetwork_internal[each.key].name
  enable_tpu                = false
  enable_shielded_nodes     = true
  remove_default_node_pool  = true
  default_max_pods_per_node = 64
  initial_node_count        = 1
  depends_on = [
    google_project_service.appsvc_container_api,
    google_project_iam_member.gke_node,
  ]
  master_auth {
    username = ""
    password = ""
    client_certificate_config {
      issue_client_certificate = false
    }
  }
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block = var.gke_master_cidr
  }
  workload_identity_config {
    identity_namespace = "${data.google_project.appsvc.project_id}.svc.id.goog"
  }
  //  pod_security_policy_config {
  //    enabled = true
  //  }
  node_config {
    service_account = google_service_account.gke_node.email
  }
  ip_allocation_policy {
    cluster_secondary_range_name  = "gke-${each.value}-pods"
    services_secondary_range_name = "gke-${each.value}-services"
  }

  master_authorized_networks_config {
    dynamic cidr_blocks {
      for_each = var.gke_master_networks

      content {
        display_name = cidr_blocks.key
        cidr_block   = cidr_blocks.value
      }
    }
  }

  vertical_pod_autoscaling {
    enabled = true
  }
  //  cluster_autoscaling {
  //    enabled = true
  //    resource_limits {
  //      resource_type = "cpu"
  //      minimum = 6
  //      maximum = 12
  //    }
  //    resource_limits {
  //      resource_type = "memory"
  //      minimum = 32
  //      maximum = 64
  //    }
  //  }
  timeouts {
    create = "1h"
  }
}

resource "google_container_node_pool" "default_pool" {
  provider           = google-beta
  for_each           = toset(var.regions)
  name               = "default-pool-unschedulable"
  cluster            = google_container_cluster.appsvc[each.key].name
  location           = each.value
  project            = data.google_project.appsvc.project_id
  max_pods_per_node  = 16
  initial_node_count = 1

  management {
    auto_repair  = true
    auto_upgrade = false
  }

  node_config {
    service_account = google_service_account.gke_node.email
    tags            = ["gke-node", "gke-${each.value}-node", "us-central1"]
    machine_type    = "e2-small"
    preemptible     = true
    oauth_scopes = [
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
    ]

    workload_metadata_config {
      node_metadata = "GKE_METADATA_SERVER"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    taint {
      key    = "CriticalAddonsOnly"
      value  = "true"
      effect = "NO_SCHEDULE"
    }
  }
}

resource "google_container_node_pool" "predefined_pool" {
  provider = google-beta
  for_each = {
    for pool in local.regional_node_pools : "${pool.region}.${pool.machine_type}" => pool
  }
  name               = "${each.value.machine_type}-pool"
  cluster            = google_container_cluster.appsvc[each.value.region].name
  location           = each.value.region
  project            = data.google_project.appsvc.project_id
  max_pods_per_node  = each.value.machine_type == "n1-standard-32" ? 64 : 32
  initial_node_count = 0

  autoscaling {
    min_node_count = 0
    max_node_count = 10
  }

  management {
    auto_repair  = true
    auto_upgrade = false
  }

  node_config {
    service_account  = google_service_account.gke_node.email
    tags             = ["gke-node", "gke-${each.value.region}-node"]
    min_cpu_platform = "Intel Skylake"
    machine_type     = each.value.machine_type
    oauth_scopes = [
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
    ]

    workload_metadata_config {
      node_metadata = "GKE_METADATA_SERVER"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }
}

resource "google_container_node_pool" "ubuntu_n1_standard_16_pool" {
  provider = google-beta

  for_each           = toset(var.regions)
  name               = "ubuntu-pool"
  cluster            = google_container_cluster.appsvc[each.value].name
  location           = each.value
  project            = data.google_project.appsvc.project_id
  max_pods_per_node  = 16
  initial_node_count = 0

  autoscaling {
    min_node_count = 1
    max_node_count = 3
  }

  management {
    auto_repair  = true
    auto_upgrade = false
  }

  node_config {
    service_account  = google_service_account.gke_node.email
    tags             = ["gke-node", "gke-${each.value}-node", "us-central1"]
    min_cpu_platform = "Intel Skylake"
    machine_type     = "n1-standard-16"
    disk_type        = "pd-ssd"
    image_type       = "UBUNTU"
    oauth_scopes = [
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
    ]

    workload_metadata_config {
      node_metadata = "GKE_METADATA_SERVER"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }
}
