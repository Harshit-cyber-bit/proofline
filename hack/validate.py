#!/usr/bin/env python3
"""Validate every layer of the repo without needing a cluster or a cloud account.

Four checks:

1.  Every YAML and HCL file parses.
2.  Every Kubernetes manifest validates against the *upstream* Kubernetes JSON
    schema for the target version, in strict mode -- so a typo'd or misplaced
    field is an error rather than something the API server silently ignores.
3.  Every kustomize overlay references files that exist, and every patch targets
    a resource that is actually in the base.
4.  Every Terraform file parses, providers are version-pinned, and no variable
    is declared without a description.

Point 2 is the one worth having. `kubectl apply --dry-run=client` does not catch
misplaced fields, and a `readinesProbe` typo will apply cleanly and do nothing
at all -- which is precisely the kind of bug that only shows up as dropped
requests during a rollout at an inconvenient hour.

Usage: python3 hack/validate.py [--k8s-version v1.31.0]
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.request
from pathlib import Path

import yaml

try:
    import hcl2
    from jsonschema import Draft7Validator
except ImportError:  # pragma: no cover
    print("error: pip install pyyaml jsonschema python-hcl2", file=sys.stderr)
    raise SystemExit(2) from None

REPO = Path(__file__).resolve().parent.parent
CACHE = REPO / ".schema-cache"

SCHEMA_BASE = (
    "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/master/"
    "{version}-standalone-strict"
)

GREEN, RED, YELLOW, DIM, RESET = (
    "\033[32m",
    "\033[31m",
    "\033[33m",
    "\033[2m",
    "\033[0m",
)

failures: list[str] = []
warnings: list[str] = []


def ok(msg: str) -> None:
    print(f"  {GREEN}ok{RESET}   {msg}")


def fail(msg: str) -> None:
    print(f"  {RED}FAIL{RESET} {msg}")
    failures.append(msg)


def warn(msg: str) -> None:
    print(f"  {YELLOW}warn{RESET} {msg}")
    warnings.append(msg)


def load_yaml(path: Path) -> list[dict]:
    return [d for d in yaml.safe_load_all(path.read_text()) if d]


def schema_name(api_version: str, kind: str) -> str:
    """Map a manifest's apiVersion/kind to its schema filename.

    Core resources are `service-v1.json`; grouped resources include the group,
    as in `deployment-apps-v1.json`.
    """
    kind = kind.lower()
    if "/" in api_version:
        group, version = api_version.split("/", 1)
        group = group.split(".")[0]
        return f"{kind}-{group}-{version}.json"
    return f"{kind}-{api_version}.json"


# API groups that ship with Kubernetes. Anything else is a CRD, and CRDs have
# no schema in the upstream repo.
CORE_GROUPS = {
    "",
    "apps",
    "batch",
    "policy",
    "networking.k8s.io",
    "rbac.authorization.k8s.io",
    "autoscaling",
    "storage.k8s.io",
    "apiextensions.k8s.io",
    "admissionregistration.k8s.io",
    "scheduling.k8s.io",
    "coordination.k8s.io",
    "node.k8s.io",
    "discovery.k8s.io",
    "certificates.k8s.io",
    "events.k8s.io",
    "flowcontrol.apiserver.k8s.io",
}


def is_custom_resource(api_version: str) -> bool:
    group = api_version.split("/")[0] if "/" in api_version else ""
    return group not in CORE_GROUPS


def fetch_schema(version: str, name: str) -> dict | None:
    CACHE.mkdir(exist_ok=True)
    cached = CACHE / f"{version}-{name}"
    if cached.exists():
        return json.loads(cached.read_text())

    url = f"{SCHEMA_BASE.format(version=version)}/{name}"
    try:
        with urllib.request.urlopen(url, timeout=30) as response:
            body = response.read().decode()
    except Exception:
        # Offline, or the schema does not exist upstream. Reported as a warning
        # by the caller rather than failing the run, so the other checks still
        # give an answer on a machine with no network.
        return None

    cached.write_text(body)
    return json.loads(body)


def check_yaml_parses() -> None:
    print(f"\n{DIM}1. every yaml file parses{RESET}")
    for path in sorted(REPO.rglob("*.y*ml")):
        if any(p in path.parts for p in (".git", ".schema-cache")):
            continue
        try:
            docs = load_yaml(path)
            ok(f"{path.relative_to(REPO)} ({len(docs)} document(s))")
        except yaml.YAMLError as exc:
            fail(f"{path.relative_to(REPO)}: {exc}")


def check_kubernetes(version: str) -> None:
    print(
        f"\n{DIM}2. kubernetes manifests validate against upstream "
        f"{version} schemas{RESET}"
    )
    manifests = sorted((REPO / "k8s" / "base").glob("*.yaml"))

    for path in manifests:
        for doc in load_yaml(path):
            kind = doc.get("kind")
            api_version = doc.get("apiVersion")
            if not kind or not api_version:
                continue
            if kind == "Kustomization":
                continue

            # Custom resources have no upstream schema by definition. Say so
            # explicitly rather than emitting a warning that trains people to
            # ignore warnings.
            if is_custom_resource(api_version):
                print(
                    f"  {DIM}skip{RESET} {path.name}: {kind} is a custom "
                    f"resource ({api_version}); no upstream schema exists"
                )
                continue

            name = schema_name(api_version, kind)
            schema = fetch_schema(version, name)
            if schema is None:
                warn(f"{path.name}: no schema for {api_version}/{kind} (offline?)")
                continue

            errors = sorted(
                Draft7Validator(schema).iter_errors(doc), key=lambda e: list(e.path)
            )
            if errors:
                for error in errors[:5]:
                    location = ".".join(str(p) for p in error.path) or "(root)"
                    fail(f"{path.name} {kind}: {location}: {error.message}")
            else:
                ok(f"{path.name}: {kind} {api_version}")


def check_overlays() -> None:
    print(f"\n{DIM}3. kustomize overlays are internally consistent{RESET}")

    base_dir = REPO / "k8s" / "base"
    base_resources: set[tuple[str, str]] = set()
    for path in base_dir.glob("*.yaml"):
        for doc in load_yaml(path):
            if doc.get("kind") and doc.get("kind") != "Kustomization":
                base_resources.add((doc["kind"], doc["metadata"]["name"]))

    for kustomization in sorted((REPO / "k8s").rglob("kustomization.yaml")):
        directory = kustomization.parent
        doc = load_yaml(kustomization)[0]
        label = str(kustomization.relative_to(REPO))

        for resource in doc.get("resources") or []:
            if not (directory / resource).exists():
                fail(f"{label}: resources references missing path {resource!r}")

        for patch in doc.get("patches") or []:
            patch_path = patch.get("path")
            if patch_path and not (directory / patch_path).exists():
                fail(f"{label}: patch references missing file {patch_path!r}")

            target = patch.get("target") or {}
            key = (target.get("kind"), target.get("name"))
            if key[0] and key not in base_resources:
                fail(
                    f"{label}: patch targets {key[0]}/{key[1]}, "
                    "which does not exist in the base"
                )

        ok(label)


def check_terraform() -> None:
    print(f"\n{DIM}4. terraform parses and follows repo conventions{RESET}")

    for path in sorted((REPO / "terraform").rglob("*.tf")):
        label = str(path.relative_to(REPO))
        try:
            with path.open() as handle:
                parsed = hcl2.load(handle)
        except Exception as exc:
            fail(f"{label}: {exc}")
            continue

        # Every declared variable needs a description. Nobody writes them later.
        for block in parsed.get("variable") or []:
            for name, body in block.items():
                if not body.get("description"):
                    fail(f"{label}: variable {name!r} has no description")

        # Providers must be version-pinned. An unpinned provider means the
        # plan you reviewed and the plan that applies next month differ.
        for block in parsed.get("terraform") or []:
            for required in block.get("required_providers") or []:
                for name, body in required.items():
                    if isinstance(body, dict) and not body.get("version"):
                        fail(f"{label}: provider {name!r} is not version-pinned")

        ok(label)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--k8s-version", default="v1.31.0")
    args = parser.parse_args()

    check_yaml_parses()
    check_kubernetes(args.k8s_version)
    check_overlays()
    check_terraform()

    print()
    if warnings:
        print(f"{YELLOW}{len(warnings)} warning(s){RESET}")
    if failures:
        print(f"{RED}{len(failures)} check(s) failed{RESET}\n")
        return 1
    print(f"{GREEN}all checks passed{RESET}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
