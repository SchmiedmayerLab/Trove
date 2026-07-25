#
# This source file is part of the StudyPlatform open-source project
#
# SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

# GCP service account used by External Secrets Operator
resource "google_service_account" "external_secrets" {
  account_id   = "external-secrets"
  display_name = "External Secrets Operator"
  project      = var.project_id
}

# Allow ESO SA to read secrets from Secret Manager
resource "google_project_iam_member" "external_secrets_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.external_secrets.email}"
}

# Workload Identity: bind K8s SA (external-secrets/external-secrets-sa)
# to the GCP SA so pods can authenticate as the GCP SA.
resource "google_service_account_iam_member" "workload_identity" {
  service_account_id = google_service_account.external_secrets.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[external-secrets/external-secrets-sa]"

  depends_on = [google_container_cluster.primary]
}
