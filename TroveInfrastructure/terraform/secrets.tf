#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

locals {
  secrets = toset([
    "server-db-credentials",
    "server-runtime-db-credentials",
    "keycloak-db-credentials",
    "keycloak-admin-credentials",
    "server-credentials",
  ])
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

# Operators provision values through Secret Manager before synchronization.
# Missing values must block deployment; never seed production with known passwords.
