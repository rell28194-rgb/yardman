#!/usr/bin/env python3
"""Fail closed on incomplete Yardman vehicle manifests.

This intentionally uses only the Python standard library so CI/recovery environments can
run it without installing jsonschema. JSON Schema remains the structural interchange spec;
this script enforces Yardman status semantics that JSON Schema alone should not guess.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

STATUS_ORDER = {
    "DISCOVERED": 0,
    "RECOVERED": 1,
    "CONVERTED": 2,
    "INTEGRATED": 3,
    "GAME-READY": 4,
    "HIGH-FIDELITY": 5,
    "ACCEPTED": 6,
}

DEPENDENCY_CATEGORIES = (
    "exterior_geometry",
    "interior_geometry",
    "lods",
    "wheels",
    "tyres",
    "brakes",
    "glass",
    "lights",
    "trim",
    "collision",
    "rig",
    "materials",
    "textures",
    "customization",
    "tuning",
    "audio",
    "source_config",
)

VALID_DEP_STATES = {"recovered", "source_absent", "not_applicable", "unresolved"}
VALID_GATE_STATES = {"pass", "fail", "not_run", "not_applicable"}
SHA256_RE = re.compile(r"^[0-9a-fA-F]{64}$")


def add(errors: list[str], condition: bool, message: str) -> None:
    if not condition:
        errors.append(message)


def nonempty_list(value) -> bool:
    return isinstance(value, list) and len(value) > 0


def audit(path: Path) -> list[str]:
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        return [f"cannot parse JSON: {exc}"]

    errors: list[str] = []

    add(errors, manifest.get("schema_version") == 1, "schema_version must equal 1")
    add(errors, isinstance(manifest.get("vehicle_id"), str) and bool(manifest.get("vehicle_id")), "vehicle_id is required")

    status = manifest.get("status")
    add(errors, status in STATUS_ORDER, f"status must be one of {', '.join(STATUS_ORDER)}")
    stage = STATUS_ORDER.get(status, -1)

    identity = manifest.get("identity")
    add(errors, isinstance(identity, dict), "identity object is required")
    if isinstance(identity, dict):
        add(errors, isinstance(identity.get("display_name"), str) and bool(identity.get("display_name")), "identity.display_name is required")
        add(errors, identity.get("confidence") in {"confirmed", "probable", "unresolved"}, "identity.confidence is invalid")
        add(errors, nonempty_list(identity.get("evidence")), "identity.evidence must be non-empty")
        if stage >= STATUS_ORDER["RECOVERED"]:
            add(errors, identity.get("confidence") != "unresolved", "RECOVERED+ vehicle cannot have unresolved identity")

    source = manifest.get("source")
    add(errors, isinstance(source, dict), "source object is required")
    if isinstance(source, dict):
        for key in ("library", "archive_family", "game_or_package", "version"):
            add(errors, isinstance(source.get(key), str) and bool(source.get(key)), f"source.{key} is required")
        add(errors, nonempty_list(source.get("root_refs")), "source.root_refs must be non-empty")
        hashes = source.get("hashes")
        add(errors, nonempty_list(hashes), "source.hashes must be non-empty")
        if isinstance(hashes, list):
            for i, value in enumerate(hashes):
                add(errors, isinstance(value, str) and bool(value), f"source.hashes[{i}] must be a non-empty string")

    deps = manifest.get("dependencies")
    add(errors, isinstance(deps, dict), "dependencies object is required")
    if isinstance(deps, dict):
        for category in DEPENDENCY_CATEGORIES:
            item = deps.get(category)
            add(errors, isinstance(item, dict), f"dependencies.{category} is required")
            if not isinstance(item, dict):
                continue
            dep_state = item.get("state")
            add(errors, dep_state in VALID_DEP_STATES, f"dependencies.{category}.state is invalid")
            items = item.get("items")
            evidence = item.get("evidence")
            add(errors, isinstance(items, list), f"dependencies.{category}.items must be a list")
            add(errors, isinstance(evidence, list), f"dependencies.{category}.evidence must be a list")

            if dep_state == "recovered":
                add(errors, nonempty_list(items), f"dependencies.{category} says recovered but has no items")
            if dep_state in {"source_absent", "not_applicable"}:
                add(errors, nonempty_list(evidence), f"dependencies.{category} requires evidence for {dep_state}")
            if stage >= STATUS_ORDER["RECOVERED"]:
                add(errors, dep_state != "unresolved", f"RECOVERED+ vehicle still has unresolved dependency category: {category}")

            if isinstance(items, list):
                for i, dep_item in enumerate(items):
                    add(errors, isinstance(dep_item, dict), f"dependencies.{category}.items[{i}] must be an object")
                    if not isinstance(dep_item, dict):
                        continue
                    add(errors, isinstance(dep_item.get("source_ref"), str) and bool(dep_item.get("source_ref")), f"dependencies.{category}.items[{i}].source_ref is required")
                    sha = dep_item.get("sha256")
                    if sha is not None:
                        add(errors, isinstance(sha, str) and bool(SHA256_RE.match(sha)), f"dependencies.{category}.items[{i}].sha256 is not 64 hex characters")

    if stage >= STATUS_ORDER["CONVERTED"]:
        master = manifest.get("neutral_master")
        add(errors, isinstance(master, dict), "CONVERTED+ vehicle requires neutral_master")
        if isinstance(master, dict):
            add(errors, nonempty_list(master.get("geometry")), "CONVERTED+ vehicle requires neutral_master.geometry")
            add(errors, isinstance(master.get("report"), str) and bool(master.get("report")), "CONVERTED+ vehicle requires neutral_master.report")

    if stage >= STATUS_ORDER["INTEGRATED"]:
        godot = manifest.get("godot")
        add(errors, isinstance(godot, dict), "INTEGRATED+ vehicle requires godot object")
        if isinstance(godot, dict):
            add(errors, isinstance(godot.get("scene"), str) and bool(godot.get("scene")), "INTEGRATED+ vehicle requires godot.scene")
            hooks = godot.get("hooks")
            add(errors, isinstance(hooks, dict), "INTEGRATED+ vehicle requires godot.hooks")
            if isinstance(hooks, dict):
                for hook in ("camera_mount", "driver_seat", "exit_point", "wheel_fl", "wheel_fr", "wheel_rl", "wheel_rr"):
                    add(errors, isinstance(hooks.get(hook), str) and bool(hooks.get(hook)), f"INTEGRATED+ vehicle missing godot.hooks.{hook}")

    validation = manifest.get("validation")
    add(errors, isinstance(validation, dict), "validation object is required")
    if isinstance(validation, dict):
        for gate in ("structural", "visual", "driving", "customization", "android", "owner_device"):
            value = validation.get(gate)
            add(errors, isinstance(value, dict), f"validation.{gate} is required")
            if not isinstance(value, dict):
                continue
            add(errors, value.get("state") in VALID_GATE_STATES, f"validation.{gate}.state is invalid")
            add(errors, isinstance(value.get("evidence"), list), f"validation.{gate}.evidence must be a list")
            if value.get("state") == "pass":
                add(errors, nonempty_list(value.get("evidence")), f"validation.{gate} passes without evidence")

        if stage >= STATUS_ORDER["GAME-READY"]:
            for gate in ("structural", "driving"):
                add(errors, isinstance(validation.get(gate), dict) and validation[gate].get("state") == "pass", f"GAME-READY+ requires validation.{gate}=pass")
        if stage >= STATUS_ORDER["HIGH-FIDELITY"]:
            for gate in ("visual", "customization"):
                add(errors, isinstance(validation.get(gate), dict) and validation[gate].get("state") in {"pass", "not_applicable"}, f"HIGH-FIDELITY+ requires validation.{gate}=pass/not_applicable")
        if stage >= STATUS_ORDER["ACCEPTED"]:
            add(errors, isinstance(validation.get("owner_device"), dict) and validation["owner_device"].get("state") == "pass", "ACCEPTED requires validation.owner_device=pass")

    critique = manifest.get("self_critique")
    add(errors, isinstance(critique, dict), "self_critique object is required")
    if isinstance(critique, dict):
        for key in ("proved", "inferred", "unresolved", "likely_owner_visible_failures"):
            add(errors, isinstance(critique.get(key), list), f"self_critique.{key} must be a list")
        if stage >= STATUS_ORDER["ACCEPTED"]:
            add(errors, not critique.get("unresolved"), "ACCEPTED vehicle cannot retain unresolved critical items")
            add(errors, not critique.get("likely_owner_visible_failures"), "ACCEPTED vehicle cannot retain likely owner-visible failures")

    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifests", nargs="+", type=Path)
    args = parser.parse_args()

    failed = False
    for path in args.manifests:
        errors = audit(path)
        if errors:
            failed = True
            print(f"FAIL {path}")
            for error in errors:
                print(f"  - {error}")
        else:
            print(f"PASS {path}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
