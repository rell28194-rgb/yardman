#!/usr/bin/env python3
import hashlib
import json
import os
import re
import sys
import zipfile

RUNTIME_STEMS = [
    "scripts/vehicle_selector_runtime",
    "scripts/vehicle_catalog",
    "scripts/fleet_vehicle_model",
    "scripts/garage_access_runtime",
    "scripts/beta1_mechanic_garage_preview_runtime",
    "scripts/remote_fleet_runtime",
    "scripts/vehicle_controller",
]
REQUIRED_STATIC = [
    "assets/data/owner_fleet_pack_contract.json",
    "assets/data/owner_fleet_runtime_manifest.json",
    "assets/data/parishes/manifest.json",
]
PACKAGED_FLEET_ROOT = "res://assets/owner_fleet_runtime/"
SOURCE_IMPORT_ROOT = "res://.godot/imported/"


def _runtime_matches(names, stem):
    prefix = "assets/" + stem
    accepted = {
        prefix + ".gdc",
        prefix + ".gd",
        prefix + ".gd.remap",
    }
    return sorted(accepted.intersection(names))


def _apk_entry_for_resource(path):
    if not isinstance(path, str) or not path.startswith("res://"):
        return ""
    return "assets/" + path[len("res://"):]


def _resolve_apk_resource(zf, names, resource):
    logical_entry = _apk_entry_for_resource(resource)
    result = {
        "logical_apk_entry": logical_entry,
        "remap_apk_entry": "",
        "resolved_apk_entry": "",
        "present": False,
    }
    if not logical_entry:
        return result
    if logical_entry in names:
        result["resolved_apk_entry"] = logical_entry
        result["present"] = True
        return result

    remap_entry = logical_entry + ".remap"
    result["remap_apk_entry"] = remap_entry if remap_entry in names else ""
    if remap_entry not in names:
        return result
    try:
        text = zf.read(remap_entry).decode("utf-8", "replace")
    except Exception:
        return result
    match = re.search(r'^\s*path(?:\.[^=]+)?\s*=\s*"([^"]+)"\s*$', text, flags=re.MULTILINE)
    if not match:
        return result
    resolved_entry = _apk_entry_for_resource(match.group(1))
    result["resolved_apk_entry"] = resolved_entry
    result["present"] = bool(resolved_entry and resolved_entry in names)
    return result


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: validate_owner_apk.py APK [DIAGNOSTICS_OUT]")
    apk = sys.argv[1]
    diagnostics_out = sys.argv[2] if len(sys.argv) > 2 else ""
    failures = []
    diag = {}

    with zipfile.ZipFile(apk) as zf:
        names = set(zf.namelist())
        diag["apk_entries"] = len(names)
        diag["required_static"] = {path: path in names for path in REQUIRED_STATIC}
        for path, present in diag["required_static"].items():
            if not present:
                failures.append("missing static APK resource: " + path)

        runtime = {stem: _runtime_matches(names, stem) for stem in RUNTIME_STEMS}
        diag["runtime_resources"] = runtime
        for stem, matches in runtime.items():
            if not matches:
                candidates = sorted(n for n in names if stem.rsplit("/", 1)[-1] in n)
                failures.append("missing runtime %s; package matches=%r" % (stem, candidates[:20]))

        contract = {}
        runtime_manifest = {}
        if "assets/data/owner_fleet_pack_contract.json" in names:
            contract = json.loads(zf.read("assets/data/owner_fleet_pack_contract.json"))
        if "assets/data/owner_fleet_runtime_manifest.json" in names:
            runtime_manifest = json.loads(zf.read("assets/data/owner_fleet_runtime_manifest.json"))

        contract_ids = list(contract.get("available_vehicle_ids", []))
        runtime_ids = list(runtime_manifest.get("vehicle_ids", []))
        diag["fleet_contract_count"] = int(contract.get("available_vehicle_count", 0))
        diag["runtime_manifest_count"] = int(runtime_manifest.get("vehicle_count", 0))
        diag["fleet_id_sets_equal"] = contract_ids == runtime_ids
        if diag["fleet_contract_count"] != 64 or len(contract_ids) != 64:
            failures.append("owner fleet contract is not exactly 64 vehicles")
        if diag["runtime_manifest_count"] != 64 or len(runtime_ids) != 64:
            failures.append("export runtime manifest is not exactly 64 vehicles")
        if contract_ids != runtime_ids:
            failures.append("export runtime vehicle IDs differ from owner fleet contract")

        compiled = []
        missing_compiled = []
        duplicate_compiled = []
        non_export_visible = []
        invalid_source_imports = []
        seen_compiled = set()
        for record in runtime_manifest.get("vehicles", []):
            vehicle_id = str(record.get("vehicle_id", ""))
            resource = str(record.get("compiled_resource", ""))
            source_compiled = str(record.get("source_compiled_resource", ""))
            resolved = _resolve_apk_resource(zf, names, resource)
            row = {
                "vehicle_id": vehicle_id,
                "resource": resource,
                "source_compiled_resource": source_compiled,
                **resolved,
            }
            compiled.append(row)
            if resource in seen_compiled:
                duplicate_compiled.append(resource)
            seen_compiled.add(resource)
            if not resource.startswith(PACKAGED_FLEET_ROOT):
                non_export_visible.append(row)
            if not source_compiled.startswith(SOURCE_IMPORT_ROOT):
                invalid_source_imports.append(row)
            if not resolved["present"]:
                missing_compiled.append(row)
        diag["compiled_vehicle_resources"] = compiled
        diag["compiled_vehicle_resource_count"] = len(compiled)
        diag["compiled_vehicle_unique_count"] = len(seen_compiled)
        diag["compiled_vehicle_missing"] = missing_compiled
        diag["compiled_vehicle_duplicates"] = duplicate_compiled
        diag["compiled_vehicle_non_export_visible"] = non_export_visible
        diag["compiled_vehicle_invalid_source_imports"] = invalid_source_imports
        if len(compiled) != 64:
            failures.append("runtime manifest does not describe exactly 64 compiled vehicle resources")
        if len(seen_compiled) != 64:
            failures.append("runtime manifest compiled vehicle resources are not 64 unique entries")
        if non_export_visible:
            failures.append("runtime manifest still points outside export-visible Fleet64 namespace for %d vehicles" % len(non_export_visible))
        if invalid_source_imports:
            failures.append("runtime manifest lost imported-source provenance for %d vehicles" % len(invalid_source_imports))
        if missing_compiled:
            failures.append("APK is missing %d packaged Fleet64 resources/remap targets: %s" % (
                len(missing_compiled), ", ".join(row["vehicle_id"] for row in missing_compiled[:12])))

        road_tiles = sum(1 for n in names if n.startswith("assets/data/roads/tile_") and n.endswith(".json"))
        coast_files = sum(1 for n in names if n.startswith("assets/data/coast/") and n != "assets/data/coast/manifest.json")
        building_tiles = sum(1 for n in names if n.startswith("assets/data/buildings/buildings_") and n.endswith(".ymb"))
        abis = sorted({n.split("/")[1] for n in names if n.startswith("lib/") and n.endswith(".so") and len(n.split("/")) > 2})
        diag["road_tiles"] = road_tiles
        diag["coast_files"] = coast_files
        diag["building_tiles"] = building_tiles
        diag["abis"] = abis
        if road_tiles < 700 or coast_files < 2500 or building_tiles < 700:
            failures.append("accepted Jamaica payload incomplete roads=%d coast=%d buildings=%d" % (road_tiles, coast_files, building_tiles))
        if abis != ["arm64-v8a"]:
            failures.append("unexpected ABI set: %r" % abis)

    size = os.path.getsize(apk)
    digest = hashlib.sha256(open(apk, "rb").read()).hexdigest()
    diag["apk_bytes"] = size
    diag["apk_sha256"] = digest
    if size < 50_000_000:
        failures.append("APK unexpectedly small: %d" % size)
    diag["failures"] = failures

    text = json.dumps(diag, indent=2, sort_keys=True)
    print("YARDMAN_OWNER_APK_DIAGNOSTICS")
    print(text)
    if diagnostics_out:
        os.makedirs(os.path.dirname(diagnostics_out) or ".", exist_ok=True)
        with open(diagnostics_out, "w", encoding="utf-8") as handle:
            handle.write(text + "\n")

    if failures:
        print("YARDMAN_RECONCILIATION_OWNER_APK_FAIL " + " | ".join(failures), file=sys.stderr)
        return 1

    print("YARDMAN_RECONCILIATION_OWNER_APK_PASS bytes=%d sha256=%s roads=%d coast_files=%d buildings=%d fleet=64 compiled_exact=64 abis=%s" % (
        size, digest, diag["road_tiles"], diag["coast_files"], diag["building_tiles"], diag["abis"]))
    sha_path = os.path.join(os.path.dirname(apk), os.path.basename(apk) + ".sha256")
    with open(sha_path, "w", encoding="utf-8") as handle:
        handle.write("%s  %s\n" % (digest, os.path.basename(apk)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
