#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

#!/usr/bin/env python3
"""Bootstrap script for Trove.

Installs ArgoCD via Helm, then hands off to ArgoCD's app-of-apps pattern.
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


def step_install_argocd():
    header("Step 1/4: Install ArgoCD")
    helm("repo", "add", "argo",
         "https://argoproj.github.io/argo-helm", "--force-update")
    helm("repo", "update")
    helm("upgrade", "--install", "argocd", "argo/argo-cd",
         "--namespace=argocd", "--create-namespace",
         f"--version={ARGOCD_CHART_VERSION}",
         "--wait", "--timeout=5m")

    print("\nWaiting for ArgoCD server...")
    kubectl("wait", "deployment/argocd-server", "-n", "argocd",
            "--for=condition=Available", "--timeout=300s")


def step_bootstrap_config(env: str):
    """Pre-apply only ConfigMaps and Namespace from bootstrap overlay.

    Certificate and IngressRoute CRDs don't exist yet (cert-manager and
    Traefik are installed later by ArgoCD). The full bootstrap overlay is
    synced by the ArgoCD bootstrap Application after operators are ready.
    """
    header("Step 2/4: Pre-apply bootstrap config")
    rendered = subprocess.run(
        ["kubectl", "kustomize", str(ROOT / "bootstrap" / env)],
        capture_output=True, text=True, check=True,
    ).stdout

    safe_kinds = {"ConfigMap", "Namespace"}
    docs = []
    for doc in rendered.split("---"):
        doc = doc.strip()
        if not doc:
            continue
        for line in doc.splitlines():
            if line.startswith("kind:"):
                kind = line.split(":", 1)[1].strip()
                if kind in safe_kinds:
                    docs.append(doc)
                break

    if docs:
        filtered = "\n---\n".join(docs)
        kubectl("apply", "-f", "-", input=filtered, text=True)
        kubectl("rollout", "restart", "deployment/argocd-server",
                "-n", "argocd")
        kubectl("wait", "deployment/argocd-server", "-n", "argocd",
                "--for=condition=Available", "--timeout=300s")


def step_configure_repository():
    """Configure access to the private manifest repository when a token is supplied."""
    header("Step 3/4: Configure repository access")
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


def application_metadata(document: str) -> tuple[str, int]:
    """Return the name and sync wave from a rendered Application manifest."""
    name = ""
    wave = 0
    in_metadata = False
    for line in document.splitlines():
        if line == "metadata:":
            in_metadata = True
            continue
        if in_metadata and line and not line.startswith(" "):
            break
        if in_metadata and line.startswith("  name:"):
            name = line.split(":", 1)[1].strip()
        if in_metadata and "argocd.argoproj.io/sync-wave:" in line:
            wave = int(line.split(":", 1)[1].strip().strip("\"'"))
    if not name:
        raise ValueError("Rendered Application is missing metadata.name")
    return name, wave


def wait_for_applications(names: list[str]):
    """Wait until every Application in a sync wave is synced and healthy."""
    deadline = time.monotonic() + APPLICATION_SYNC_TIMEOUT
    while time.monotonic() < deadline:
        result = subprocess.run(
            [
                "kubectl", "get", "applications", "-n", "argocd",
                "-o", "json",
            ],
            capture_output=True, text=True, check=True,
        )
        items = {
            item["metadata"]["name"]: item
            for item in json.loads(result.stdout).get("items", [])
        }
        states = []
        all_ready = True
        for name in names:
            status = items.get(name, {}).get("status", {})
            sync = status.get("sync", {}).get("status", "Unknown")
            health = status.get("health", {}).get("status", "Unknown")
            states.append(f"{name}={sync}/{health}")
            if sync != "Synced" or health != "Healthy":
                all_ready = False
        print(f"  {' '.join(states)}")
        if all_ready:
            return
        time.sleep(15)
    raise TimeoutError(
        f"Applications did not become ready within {APPLICATION_SYNC_TIMEOUT}s: "
        + ", ".join(names)
    )


def step_apply_applications(env: str, branch: str):
    """Apply ArgoCD Applications.

    For dev: applies child Applications directly (no root app) with
    targetRevision patched to the working branch. This avoids the
    circular problem where a root app would revert children back to main.

    For prod: applies the root Application which manages everything
    via the app-of-apps pattern from the main branch.
    """
    header("Step 4/4: Apply ArgoCD Applications")

    if env == "prod":
        root_yaml = (ROOT / "argocd-apps" / env / "root-app.yaml").read_text()
        kubectl("apply", "-f", "-", input=root_yaml, text=True)
        return

    # Dev: apply child Applications directly with branch override.
    # argocd-apps/dev/kustomization.yaml excludes root-app.yaml so
    # there is no self-managing root app that would revert children.
    rendered = subprocess.run(
        ["kubectl", "kustomize", str(ROOT / "argocd-apps" / env)],
        capture_output=True, text=True, check=True,
    ).stdout
    docs = rendered.split("\n---\n")
    applications: dict[int, list[tuple[str, str]]] = {}
    for doc in docs:
        if "kind: Application" in doc:
            doc = doc.replace(
                "targetRevision: main", f"targetRevision: {branch}")
            name, wave = application_metadata(doc)
            applications.setdefault(wave, []).append((name, doc))

    # Dev has no root Application, so ArgoCD cannot orchestrate the child
    # Application sync waves for us. Apply and await each wave explicitly.
    for wave in sorted(applications):
        wave_apps = applications[wave]
        names = [name for name, _ in wave_apps]
        print(f"\nApplying Application sync wave {wave}: {', '.join(names)}")
        wave_manifest = "\n---\n".join(doc for _, doc in wave_apps)
        kubectl("apply", "-f", "-", input=wave_manifest, text=True)
        wait_for_applications(names)


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

    branch = args.branch or get_current_branch()

    if args.env == "dev":
        if not branch_exists_on_remote(branch):
            print(f"\nError: Branch '{branch}' not found on remote 'origin'.")
            print("Push your branch first: git push -u origin HEAD")
            sys.exit(1)
        print(f"  Branch: {branch}")

    step_install_argocd()
    step_bootstrap_config(args.env)
    step_configure_repository()
    step_apply_applications(args.env, branch)

    domain = "localhost" if args.env == "dev" else "console.troveplatform.org"
    print(f"""
=====================================
  Bootstrap complete!
=====================================
  ArgoCD will now sync all resources.
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
