#!/usr/bin/env bash
#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

set -euo pipefail

APPS="cert-manager cnpg-operator external-secrets-operator traefik bootstrap infrastructure apps"
TIMEOUT="${SMOKE_TEST_TIMEOUT:-600}"
INTERVAL=15
ELAPSED=0

echo "Waiting for ArgoCD Applications to sync and become healthy..."
echo "Applications: $APPS"
echo "Timeout: ${TIMEOUT}s"
echo ""

while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  ALL_READY=true
  for app in $APPS; do
    HEALTH=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
    SYNC=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
    if [ "$HEALTH" != "Healthy" ] || [ "$SYNC" != "Synced" ]; then
      ALL_READY=false
    fi
  done

  if [ "$ALL_READY" = true ]; then
    echo ""
    echo "All applications are Synced and Healthy!"
    kubectl get applications -n argocd
    # Pod readiness alone does not prove that NodePort and ingress policies agree.
    # Trust only this disposable cluster's self-signed certificate, never disable TLS checks.
    certificate=$(mktemp)
    trap 'rm -f "$certificate"' EXIT
    kubectl get secret trove-main-tls-secret -n trove -o jsonpath='{.data.tls\.crt}' \
      | base64 --decode > "$certificate"
    for path in / /api/v0/health /auth/realms/trove/.well-known/openid-configuration; do
      curl --fail --silent --show-error --max-time 15 \
        --retry 6 --retry-all-errors --retry-delay 5 --retry-max-time 120 \
        --cacert "$certificate" --resolve localhost:443:127.0.0.1 \
        "https://localhost$path" > /dev/null
    done
    echo "PASS: web, API health and identity discovery are reachable through verified local TLS."
    exit 0
  fi

  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
  echo "[${ELAPSED}s/${TIMEOUT}s] Waiting..."
  kubectl get applications -n argocd --no-headers 2>/dev/null || true
done

echo ""
echo "TIMEOUT: Not all applications reached Synced+Healthy within ${TIMEOUT}s"
kubectl get applications -n argocd -o wide
exit 1
