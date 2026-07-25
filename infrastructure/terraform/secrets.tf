#
# This source file is part of the StudyPlatform open-source project
#
# SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

locals {
  secrets = {
    "server-db-credentials" = {
      placeholder = jsonencode({ username = "studyplatform", password = "studyplatform" })
    }
    "keycloak-db-credentials" = {
      placeholder = jsonencode({ username = "keycloak", password = "keycloak" })
    }
    "keycloak-admin-credentials" = {
      placeholder = jsonencode({ username = "admin", password = "admin" })
    }
    "server-credentials" = {
      placeholder = jsonencode({ KEYCLOAK_CLIENT_SECRET = "change-after-keycloak-setup" })
    }
  }
}

resource "google_secret_manager_secret" "secrets" {
  for_each = local.secrets

  secret_id = each.key
  project   = var.project_id

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

# Seed each secret with a placeholder so ESO does not fail on first sync.
# After apply, replace these values via the GCP console or gcloud CLI.
resource "google_secret_manager_secret_version" "initial" {
  for_each = local.secrets

  secret      = google_secret_manager_secret.secrets[each.key].id
  secret_data = each.value.placeholder

  lifecycle {
    ignore_changes = [secret_data]
  }
}
