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
    python tools/setup.py --revision SHA     # dev, exact clean checkout (CI)
    python tools/setup.py --env prod         # prod, main branch
"""

import argparse
import ipaddress
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
KIND_API_CIDR_PLACEHOLDER = '"__KIND_API_CIDR__"'


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


def commit_revision(value: str) -> str:
    if len(value) != 40 or any(character not in "0123456789abcdefABCDEF" for character in value):
        raise argparse.ArgumentTypeError("revision must be a full 40-character commit SHA")
    return value.lower()


def verify_checkout_revision(revision: str) -> None:
    """Exact-revision deployment must describe the source used to build the images."""
    head = subprocess.run(
        ["git", "rev-parse", "--verify", "HEAD"],
        capture_output=True, text=True, check=True, cwd=ROOT,
    ).stdout.strip()
    if head != revision:
        raise ValueError("The deployment revision does not match the checked-out commit")
    changes = subprocess.run(
        ["git", "status", "--porcelain"],
        capture_output=True, text=True, check=True, cwd=ROOT,
    ).stdout.strip()
    if changes:
        raise ValueError("Exact-revision deployment requires a clean checkout; local changes are not in the remote commit")


def header(msg: str):
    print(f"\n{'=' * 60}\n  {msg}\n{'=' * 60}\n")


def kind_api_cidr() -> str:
    """Allow only the actual single-node KIND API endpoint after Service DNAT."""
    result = kubectl(
        "get", "endpointslices", "-n", "default",
        "-l", "kubernetes.io/service-name=kubernetes", "-o", "json",
        capture_output=True, text=True,
    )
    slices = json.loads(result.stdout)["items"]
    addresses = set()
    for item in slices:
        if item.get("addressType") != "IPv4" or item.get("ports") != [
            {"name": "https", "port": 6443, "protocol": "TCP"}
        ]:
            raise ValueError("Expected the single-node KIND IPv4 API on TCP port 6443")
        for endpoint in item["endpoints"]:
            if endpoint.get("conditions", {}).get("ready") is not True:
                raise ValueError("The KIND API endpoint is not ready")
            addresses.update(ipaddress.IPv4Address(value) for value in endpoint["addresses"])
    if len(addresses) != 1:
        raise ValueError("Expected exactly one KIND API address")
    return f"{addresses.pop()}/32"


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
    # Keep credentials out of process arguments, printed commands and exception text.
    # Server-side apply also avoids copying stringData into a last-applied annotation.
    manifest = {
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": {
            "name": "trove-repository",
            "namespace": "argocd",
            "labels": {"argocd.argoproj.io/secret-type": "repository"},
        },
        "stringData": {
            "type": "git",
            "url": repository_url,
            "username": "x-access-token",
            "password": token,
        },
    }
    kubectl("apply", "--server-side", "-f", "-", input=json.dumps(manifest), text=True)


def wait_for_application(name: str, revision: str):
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
        compared_revision = status.get("sync", {}).get("comparedTo", {}).get("source", {}).get("targetRevision")
        if sync == "Synced" and health == "Healthy" and compared_revision == revision:
            return
        time.sleep(15)
    raise TimeoutError(
        f"Application {name} did not become ready within "
        f"{APPLICATION_SYNC_TIMEOUT}s"
    )


def step_apply_root_application(env: str, revision: str):
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
            TARGET_REVISION_PLACEHOLDER, json.dumps(revision)
        )
        if KIND_API_CIDR_PLACEHOLDER not in root_yaml:
            raise ValueError(f"{root_path} is missing the KIND API address placeholder")
        root_yaml = root_yaml.replace(KIND_API_CIDR_PLACEHOLDER, json.dumps(kind_api_cidr()))

    root_name = f"root-{env}"
    kubectl("apply", "-f", "-", input=root_yaml, text=True)
    print("\nWaiting for ArgoCD to sync the application tree...")
    wait_for_application(root_name, revision)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(
        description="Bootstrap Trove")
    parser.add_argument(
        "--env", choices=["dev", "prod"], default="dev",
        help="Target environment (default: dev)")
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument(
        "--branch",
        help="Git branch for ArgoCD to track (dev only, default: current branch)")
    selection.add_argument(
        "--revision", type=commit_revision,
        help="Exact commit used for images and manifests; requires a clean matching checkout (dev only)")
    args = parser.parse_args()

    if args.env == "prod" and (args.branch or args.revision):
        parser.error("--branch and --revision are supported only for the dev environment")

    if args.revision:
        verify_checkout_revision(args.revision)
        revision = args.revision
    else:
        revision = (args.branch or get_current_branch()) if args.env == "dev" else "main"
        if args.env == "dev" and not branch_exists_on_remote(revision):
            print(f"\nError: Branch '{revision}' not found on remote 'origin'.")
            print("Push your branch first: git push -u origin HEAD")
            sys.exit(1)
    print(f"  Revision: {revision}")

    step_install_argocd(args.env)
    step_configure_repository()
    step_apply_root_application(args.env, revision)

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
