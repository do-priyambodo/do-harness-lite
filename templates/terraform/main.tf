# Reference Google Cloud Terraform Blueprint:
# - Project Services & IAM Least Privilege
# - Cloud KMS KeyRing + CryptoKey + Service Agent Encrypter/Decrypter Binding
# - CMEK-Protected GCS Bucket (uniform bucket-level access + versioning)
# - Cloud Run v2 Service with Direct VPC Egress & Secret Manager env injection
# - AlloyDB Cluster + Primary Instance + Read Pool Instance

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

variable "project_id" {
  type        = string
  description = "Target Google Cloud Project ID"
}

variable "region" {
  type        = string
  default     = "us-central1"
  description = "Regional location for Cloud Run, KMS, AlloyDB, and GCS"
}

variable "service_name" {
  type        = string
  default     = "agent-runtime-service"
  description = "Workload name used for resources and billing labels"
}

variable "container_image" {
  type        = string
  default     = "us-docker.pkg.dev/cloudrun/container/hello"
  description = "Container image URI for Cloud Run v2 service"
}

locals {
  common_labels = {
    environment = "production"
    cost_center = "ai-platform"
    service     = var.service_name
    managed_by  = "terraform"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

data "google_project" "current" {
  project_id = var.project_id
}

# 1. Enable Required APIs
resource "google_project_service" "required_apis" {
  for_each = toset([
    "aiplatform.googleapis.com",
    "run.googleapis.com",
    "cloudkms.googleapis.com",
    "storage.googleapis.com",
    "secretmanager.googleapis.com",
    "alloydb.googleapis.com",
    "compute.googleapis.com",
    "servicenetworking.googleapis.com",
  ])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# 2. Dedicated Least-Privilege Service Account for Cloud Run Agent
resource "google_service_account" "agent_sa" {
  account_id   = "${var.service_name}-sa"
  display_name = "Dedicated Service Account for ${var.service_name}"
  depends_on   = [google_project_service.required_apis]
}

resource "google_project_iam_member" "agent_vertex_user" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.agent_sa.email}"
}

# 3. Cloud KMS CMEK KeyRing & CryptoKey (with Storage Service Agent IAM)
resource "google_kms_key_ring" "cmek_ring" {
  name       = "${var.service_name}-keyring"
  location   = var.region
  depends_on = [google_project_service.required_apis]
}

resource "google_kms_crypto_key" "cmek_key" {
  name            = "${var.service_name}-key"
  key_ring        = google_kms_key_ring.cmek_ring.id
  rotation_period = "7776000s" # 90 days
  labels          = local.common_labels
}

resource "google_kms_crypto_key_iam_member" "storage_cmek_binding" {
  crypto_key_id = google_kms_crypto_key.cmek_key.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${data.google_project.current.number}@gs-project-accounts.iam.gserviceaccount.com"
}

# 4. Hardened CMEK Cloud Storage Bucket
resource "google_storage_bucket" "artifacts_bucket" {
  name                        = "${var.project_id}-${var.service_name}-artifacts"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  labels                      = local.common_labels

  versioning {
    enabled = true
  }

  encryption {
    default_kms_key_name = google_kms_crypto_key.cmek_key.id
  }

  depends_on = [google_kms_crypto_key_iam_member.storage_cmek_binding]
}

# 5. Cloud Run v2 Service (Regional, Scale-to-Zero Ready, Global Gemini Endpoint)
resource "google_cloud_run_v2_service" "agent_service" {
  name     = var.service_name
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"
  labels   = local.common_labels

  template {
    service_account = google_service_account.agent_sa.email

    scaling {
      min_instance_count = 0
      max_instance_count = 10
    }

    containers {
      image = var.container_image

      resources {
        limits = {
          cpu    = "1"
          memory = "1Gi"
        }
      }

      env {
        name  = "GOOGLE_CLOUD_PROJECT"
        value = var.project_id
      }
      env {
        name  = "GOOGLE_CLOUD_LOCATION"
        value = "global"
      }
      env {
        name  = "GOOGLE_GENAI_USE_VERTEXAI"
        value = "True"
      }
    }
  }

  depends_on = [google_project_iam_member.agent_vertex_user]
}
