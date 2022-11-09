terraform {
  required_version = ">= 0.14"
  required_providers {
    google = ">= 3.3"
  }
}

provider "google" {
  project = "ninth-rain-364409"
}

# Enables the Cloud Run API
resource "google_project_service" "run_api" {
  service = "run.googleapis.com"
  disable_on_destroy = true
}

# Create the Cloud Run service
resource "google_cloud_run_service" "run_service" {
  name = "hello-world-service"
  location = "us-central1"
  template {
    spec {
        containers {
             image = "gcr.io/cloudrun/hello"
        }
    }
  }
  traffic {
    percent         = 100
    latest_revision = true
  }
  # Waits for the Cloud Run API to be enabled
  depends_on = [google_project_service.run_api]
}

# Allow unauthenticated users to invoke the service
resource "google_cloud_run_service_iam_member" "run_all_users" {
  service  = google_cloud_run_service.run_service.name
  location = google_cloud_run_service.run_service.location
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# Create the Cloudbuild
resource "google_cloudbuild_trigger" "filename-trigger" {

  github {
           name  = "git-runner-terraform" 
           owner = "Varunarora2201"

           push {
               branch       = "^main$"
               invert_regex = false
            }
        }

  filename = "cloudbuild.yaml"
}
resource "google_clouddeploy_target" "primary" {
  location = "us-west1"
  name     = "target"

#Optional
#---
  annotations = {
    my_first_annotation = "example-annotation-1"

    my_second_annotation = "example-annotation-2"
  }
#---
  description = "basic description"

#Use one of them
#---
   gke {
     cluster = "projects/my-project-name/locations/us-west1/clusters/example-cluster-name"
   }

   anthos_cluster {
     membership = "projects/{project}/locations/{location}/memberships/{membership_name}"
   }
#---

#Optional
#---
  labels = {
    my_first_label = "example-label-1"

    my_second_label = "example-label-2"
  }
  project          = "my-project-name"
  require_approval = false
#---
}
locals {
  network_name    = var.create_network ? google_compute_network.gh-network[0].self_link : var.network_name
  subnet_name     = var.create_subnetwork ? google_compute_subnetwork.gh-subnetwork[0].self_link : var.subnet_name
  service_account = var.service_account == "" ? google_service_account.runner_service_account[0].email : var.service_account
  startup_script  = var.startup_script == "" ? file("${path.module}/scripts/startup.sh") : var.startup_script
  shutdown_script = var.shutdown_script == "" ? file("${path.module}/scripts/shutdown.sh") : var.shutdown_script
}

/***************
  Optional Runner Networking
 ***************/
resource "google_compute_network" "gh-network" {
  count                   = var.create_network ? 1 : 0
  name                    = var.network_name
  project                 = var.project_id
  auto_create_subnetworks = false
}
resource "google_compute_subnetwork" "gh-subnetwork" {
  count         = var.create_subnetwork ? 1 : 0
  project       = var.project_id
  name          = var.subnet_name
  ip_cidr_range = var.subnet_ip
  region        = var.region
  network       = local.network_name
}

resource "google_compute_router" "default" {
  count   = var.create_network ? 1 : 0
  name    = "${var.network_name}-router"
  network = google_compute_network.gh-network[0].self_link
  region  = var.region
  project = var.project_id
}

resource "google_compute_router_nat" "nat" {
  count                              = var.create_network ? 1 : 0
  project                            = var.project_id
  name                               = "${var.network_name}-nat"
  router                             = google_compute_router.default[0].name
  region                             = google_compute_router.default[0].region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

/***************
  IAM Bindings GCE SVC
 ***************/

resource "google_service_account" "runner_service_account" {
  count        = var.service_account == "" ? 1 : 0
  project      = var.project_id
  account_id   = "runner-service-account"
  display_name = "Github Runner GCE Service Account"
}

/***************
  Runner Secrets
 ***************/
resource "google_secret_manager_secret" "gh-secret" {
  provider  = google-beta
  project   = var.project_id
  secret_id = "gh-token"

  labels = {
    label = "gh-token"
  }

  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
}
resource "google_secret_manager_secret_version" "gh-secret-version" {
  provider = google-beta
  secret   = google_secret_manager_secret.gh-secret.id
  secret_data = jsonencode({
    "REPO_NAME"    = var.repo_name
    "REPO_OWNER"   = var.repo_owner
    "GITHUB_TOKEN" = var.gh_token
    "LABELS"       = join(",", var.gh_runner_labels)
  })
}


resource "google_secret_manager_secret_iam_member" "gh-secret-member" {
  provider  = google-beta
  project   = var.project_id
  secret_id = google_secret_manager_secret.gh-secret.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${local.service_account}"
}

/***************
  Runner GCE Instance Template
 ***************/
locals {
  instance_name = "gh-runner-vm"
}


module "mig_template" {
  source             = "terraform-google-modules/vm/google//modules/instance_template"
  version            = "~> 7.0"
  project_id         = var.project_id
  machine_type       = var.machine_type
  network            = local.network_name
  subnetwork         = local.subnet_name
  region             = var.region
  subnetwork_project = var.subnetwork_project != "" ? var.subnetwork_project : var.project_id
  service_account = {
    email = local.service_account
    scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
  }
  disk_size_gb         = 100
  disk_type            = "pd-ssd"
  auto_delete          = true
  name_prefix          = "gh-runner"
  source_image_family  = var.source_image_family
  source_image_project = var.source_image_project
  startup_script       = local.startup_script
  source_image         = var.source_image
  metadata = merge({
    "secret-id" = google_secret_manager_secret_version.gh-secret-version.name
    }, {
    "shutdown-script" = local.shutdown_script
  }, var.custom_metadata)
  tags = [
    "gh-runner-vm"
  ]
}
/***************
  Runner MIG
 ***************/
module "mig" {
  source             = "terraform-google-modules/vm/google//modules/mig"
  version            = "~> 7.0"
  project_id         = var.project_id
  subnetwork_project = var.project_id
  hostname           = local.instance_name
  region             = var.region
  instance_template  = module.mig_template.self_link

  /* autoscaler */
  autoscaling_enabled = true
  min_replicas        = var.min_replicas
  max_replicas        = var.max_replicas
  cooldown_period     = var.cooldown_period
}
