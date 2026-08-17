#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

#!/usr/bin/env python3
"""Bootstrap script for Trove.

Installs and configures ArgoCD, then hands off to its app-of-apps pattern.
Works for both dev (KIND) and prod (real cluster).

Usage:
    python tools/setup.py                    # dev, current git branch
    python tools/setup.py --branch feature   # dev, specific branch
    python tools/setup.py --env prod         # prod, main branch
"""

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ARGOCD_CHART_VERSION = "9.5.1"
APPLICATION_SYNC_TIMEOUT = int(os.environ.get("APPLICATION_SYNC_TIMEOUT", "1200"))
TARGET_REVISION_PLACEHOLDER = '"__TARGET_REVISION__"'


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    print(f"  $ {' '.join(cmd)}")
    return subprocess.run(cmd, check=True, **kwargs)


def kubectl(*args: str, **kwargs) -> subprocess.CompletedProcess:
    return run(["kubectl", *args], **kwargs)


def helm(*args: str, **kwargs) -> subprocess.CompletedProcess:
    return run(["helm", *args], **kwargs)


def get_current_branch() -> str:
    for var in ("GITHUB_HEAD_REF", "GITHUB_REF_NAME"):
        val = os.environ.get(var, "").strip()
        if val:
            return val
    result = subprocess.run(
        ["git", "rev-parse", "--abbrev-ref", "HEAD"],
        capture_output=True, text=True, check=True, cwd=ROOT,
    )
    return result.stdout.strip()


def branch_exists_on_remote(branch: str) -> bool:
    result = subprocess.run(
        ["git", "ls-remote", "--heads", "origin", branch],
        capture_output=True, text=True, cwd=ROOT,
    )
    return branch in result.stdout


def header(msg: str):
    print(f"\n{'=' * 60}\n  {msg}\n{'=' * 60}\n")


# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------


def step_install_argocd(env: str):
    header("Step 1/3: Install and configure ArgoCD")
    helm("repo", "add", "argo",
         "https://argoproj.github.io/argo-helm", "--force-update")
    helm("repo", "update")
    helm("upgrade", "--install", "argocd", "argo/argo-cd",
         "--namespace=argocd", "--create-namespace",
         f"--version={ARGOCD_CHART_VERSION}",
         "--values", str(ROOT / "bootstrap" / "helm-values" / "base.yaml"),
         "--values", str(ROOT / "bootstrap" / "helm-values" / f"{env}.yaml"),
         "--wait", "--timeout=5m")

    print("\nWaiting for ArgoCD server...")
    kubectl("wait", "deployment/argocd-server", "-n", "argocd",
            "--for=condition=Available", "--timeout=300s")


def step_configure_repository():
    """Configure access to the private manifest repository when a token is supplied."""
    header("Step 2/3: Configure repository access")
    token = os.environ.get("REPOSITORY_TOKEN", "").strip()
    if not token:
        print("  REPOSITORY_TOKEN is not set; using existing ArgoCD credentials.")
        return

    repository_url = os.environ.get(
        "REPOSITORY_URL", "https://github.com/SchmiedmayerLab/Trove.git"
    ).strip()
    manifest = subprocess.run(
        [
            "kubectl", "create", "secret", "generic", "trove-repository",
            "--namespace", "argocd",
            "--from-literal=type=git",
            f"--from-literal=url={repository_url}",
            "--from-literal=username=x-access-token",
            f"--from-literal=password={token}",
            "--dry-run=client", "-o", "yaml",
        ],
        capture_output=True, text=True, check=True,
    ).stdout
    kubectl("apply", "-f", "-", input=manifest, text=True)
    kubectl(
        "label", "secret", "trove-repository", "-n", "argocd",
        "argocd.argoproj.io/secret-type=repository", "--overwrite",
    )


def wait_for_application(name: str):
    """Wait for ArgoCD to reconcile the root Application and all its children."""
    deadline = time.monotonic() + APPLICATION_SYNC_TIMEOUT
    while time.monotonic() < deadline:
        result = subprocess.run(
            [
                "kubectl", "get", f"application/{name}", "-n", "argocd",
                "-o", "json",
            ],
            capture_output=True, text=True, check=True,
        )
        status = json.loads(result.stdout).get("status", {})
        sync = status.get("sync", {}).get("status", "Unknown")
        health = status.get("health", {}).get("status", "Unknown")
        print(f"  {name}={sync}/{health}")
        if sync == "Synced" and health == "Healthy":
            return
        time.sleep(15)
    raise TimeoutError(
        f"Application {name} did not become ready within "
        f"{APPLICATION_SYNC_TIMEOUT}s"
    )


def step_apply_root_application(env: str, branch: str):
    """Create the root Application and let ArgoCD orchestrate every child."""
    header("Step 3/3: Apply root Application")

    root_path = ROOT / "argocd-apps" / env / "root-app.yaml"
    root_yaml = root_path.read_text()
    if env == "dev":
        if TARGET_REVISION_PLACEHOLDER not in root_yaml:
            raise ValueError(
                f"{root_path} is missing the target revision placeholder"
            )
        # JSON strings are valid YAML scalars and safely quote any valid Git ref.
        root_yaml = root_yaml.replace(
            TARGET_REVISION_PLACEHOLDER, json.dumps(branch)
        )

    root_name = f"root-{env}"
    kubectl("apply", "-f", "-", input=root_yaml, text=True)
    print("\nWaiting for ArgoCD to sync the application tree...")
    wait_for_application(root_name)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(
        description="Bootstrap Trove")
    parser.add_argument(
        "--env", choices=["dev", "prod"], default="dev",
        help="Target environment (default: dev)")
    parser.add_argument(
        "--branch",
        help="Git branch for ArgoCD to track (dev only, default: current branch)")
    args = parser.parse_args()

    if args.env == "prod" and args.branch:
        parser.error("--branch is supported only for the dev environment")

    branch = (args.branch or get_current_branch()) if args.env == "dev" else "main"

    if args.env == "dev":
        if not branch_exists_on_remote(branch):
            print(f"\nError: Branch '{branch}' not found on remote 'origin'.")
            print("Push your branch first: git push -u origin HEAD")
            sys.exit(1)
        print(f"  Branch: {branch}")

    step_install_argocd(args.env)
    step_configure_repository()
    step_apply_root_application(args.env, branch)

    domain = "localhost" if args.env == "dev" else "console.troveplatform.org"
    print(f"""
=====================================
  Bootstrap complete!
=====================================
  ArgoCD has synced all resources.
  Monitor: kubectl get applications -n argocd

  Main App:        https://{domain}
  Server API:      https://{domain}/api
  Keycloak Admin:  https://{domain}/auth/admin
  ArgoCD:          https://{domain}/argo
=====================================
""")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as e:
        print(f"\nFailed: {e}", file=sys.stderr)
        sys.exit(1)
    except (TimeoutError, ValueError) as e:
        print(f"\nFailed: {e}", file=sys.stderr)
        sys.exit(1)
