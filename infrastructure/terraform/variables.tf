#
# This source file is part of the StudyPlatform open-source project
#
# SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

variable "project_id" {
  description = "GCP project ID"
  type        = string
  default     = "studyplatform-dev"
}

variable "region" {
  description = "GCP region for all resources"
  type        = string
  default     = "us-west1"
}

variable "cluster_name" {
  description = "Name of the GKE cluster"
  type        = string
  default     = "studyplatform-dev"
}

variable "zone" {
  description = "GCP zone for the GKE cluster"
  type        = string
  default     = "us-west1-a"
}

variable "domain" {
  description = "Domain for the platform (used in output instructions)"
  type        = string
  default     = "platform.spezi.stanford.edu"
}

variable "authorized_networks" {
  description = "CIDRs allowed to reach the GKE control plane"
  type = list(object({
    display_name = string
    cidr_block   = string
  }))
  default = [
    {
      display_name = "all"
      cidr_block   = "0.0.0.0/0"
    }
  ]
}
