#!/usr/bin/env python3
"""Recover CarX Drift vehicle catalog + source tuning stages from a verified OBB.

This is donor-source recovery for Yardman. It does not patch or execute CarX.

Inputs:
- original CarX OBB ZIP
- Yardman's `carx_drift_full-objects.ndjson.gz` inventory
- optional original PlayerCars.xml

The Unity source stores per-vehicle physics presets as TextAssets named like:
`ToyotaSupraRZStock`, `ToyotaSupraRZTurbo`, `ToyotaSupraRZDrift`,
`ToyotaSupraRZRacing`, `ToyotaSupraRZUltimate`.

The tool discovers all such families, verifies the serialized member hash against
inventory evidence, extracts the embedded XML, and converts it losslessly into a
JSON tree while preserving the raw XML SHA-256 and source member identity.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import re
import sys
import xml.etree.ElementTree as ET
import zipfile
from collections import defaultdict
from pathlib import Path
from typing import Any

STAGES = ("Stock", "Turbo", "Drift", "Racing", "Ultimate")


def scalar(text: str) -> Any:
    value = text.strip()
    if value.lower() == "true":
        return True
    if value.lower() == "false":
        return False
    if re.fullmatch(r"-?\d+", value):
        try:
            return int(value)
        except ValueError:
            pass
    if re.fullmatch(r"-?(?:\d+\.\d*|\d*\.\d+)(?:[eE][+-]?\d+)?", value):
        try:
            return float(value)
        except ValueError:
            pass
    return value


def xml_node(node: ET.Element) -> Any:
    children = list(node)
    if not children:
        return scalar(node.text or "")
    names = [child.tag for child in children]
    if len(set(names)) == 1:
        return [xml_node(child) for child in children]
    result: dict[str, Any] = {}
    for child in children:
        value = xml_node(child)
        if child.tag in result:
            previous = result[child.tag]
            if not isinstance(previous, list):
                result[child.tag] = [previous]
            result[child.tag].append(value)
        else:
            result[child.tag] = value
    return result


def extract_embedded_xml(serialized: bytes) -> str:
    start = serialized.find(b"<?xml")
    end = serialized.find(b"</Desc>", start)
    if start < 0 or end < 0:
        raise ValueError("serialized TextAsset contains no <Desc> XML")
    end += len(b"</Desc>")
    return serialized[start:end].decode("utf-8")


def load_inventory(path: Path) -> dict[str, dict[str, dict[str, Any]]]:
    families: dict[str, dict[str, dict[str, Any]]] = defaultdict(dict)
    with gzip.open(path, "rt", encoding="utf-8", errors="replace") as stream:
        for line in stream:
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if record.get("type") != "TextAsset":
                continue
            name = str(record.get("name") or "")
            for stage in STAGES:
                if name.endswith(stage) and len(name) > len(stage):
                    families[name[: -len(stage)]][stage] = record
                    break
    return dict(families)


def load_catalog(path: Path | None) -> list[dict[str, Any]]:
    if path is None:
        return []
    root = ET.parse(path).getroot()
    records: list[dict[str, Any]] = []
    for node in root.iter("PlayerCar"):
        attrs = dict(node.attrib)
        records.append(
            {
                "id": int(attrs.get("id", -1)),
                "enabled": attrs.get("enabled", "false").lower() == "true",
                "forced_disable": attrs.get("forcedDisable", "false").lower() == "true",
                "display_name": attrs.get("name", ""),
                "icon": attrs.get("icon", ""),
                "prefab": attrs.get("prefab", ""),
                "identifier": attrs.get("identifier", ""),
                "showroom_class": int(attrs.get("showRoomClass", 0) or 0),
                "customization_enabled": attrs.get("customizationEnabled", "false").lower() == "true",
                "defaults": {
                    "color_id": int(attrs.get("dColorId", -1) or -1),
                    "wheel_cap_id": int(attrs.get("dWheelCapId", -1) or -1),
                    "rim_color_id": int(attrs.get("dRimColorId", -1) or -1),
                    "spoke_color_id": int(attrs.get("dSpokeColorId", -1) or -1),
                    "wheel_tire_id": int(attrs.get("dWheelTireId", -1) or -1),
                    "smoke_color_id": int(attrs.get("dSmokeColorId", -1) or -1),
                    "glass_color_id": int(attrs.get("dGlassColorId", -1) or -1),
                },
                "non_colored_parts": [
                    (child.text or "").strip()
                    for parent in node.findall("nonColoredParts")
                    for child in list(parent)
                    if (child.text or "").strip()
                ],
            }
        )
    return records


def member_name(file_id: str) -> str:
    return f"assets/bin/Data/{file_id}"


def recover_family(
    family: str,
    stage_records: dict[str, dict[str, Any]],
    obb: zipfile.ZipFile,
) -> dict[str, Any]:
    result: dict[str, Any] = {
        "family": family,
        "complete_five_stage_family": all(stage in stage_records for stage in STAGES),
        "available_stages": [stage for stage in STAGES if stage in stage_records],
        "stages": {},
    }
    for stage in STAGES:
        record = stage_records.get(stage)
        if record is None:
            continue
        file_id = str(record["file"])
        name = member_name(file_id)
        serialized = obb.read(name)
        serialized_sha = hashlib.sha256(serialized).hexdigest()
        inventory_sha = str(record.get("file_sha256") or record.get("serialized_file_sha256") or "")
        # The NDJSON object's `sha256` is the object-body hash, not necessarily the
        # entire serialized member. Only enforce a whole-member hash when the
        # inventory explicitly supplies one.
        if inventory_sha and serialized_sha.lower() != inventory_sha.lower():
            raise ValueError(f"whole-member SHA mismatch for {family}{stage}: {file_id}")
        xml_text = extract_embedded_xml(serialized)
        xml_root = ET.fromstring(xml_text)
        result["stages"][stage.lower()] = {
            "textasset_name": str(record.get("name") or f"{family}{stage}"),
            "source_member": file_id,
            "source_member_bytes": len(serialized),
            "source_member_sha256": serialized_sha,
            "inventory_object_sha256": record.get("sha256"),
            "xml_sha256": hashlib.sha256(xml_text.encode("utf-8")).hexdigest(),
            "data": xml_node(xml_root),
        }
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--obb", required=True, type=Path)
    parser.add_argument("--inventory", required=True, type=Path)
    parser.add_argument("--player-cars", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--family", action="append", help="Recover only the named source family; repeatable")
    args = parser.parse_args()

    families = load_inventory(args.inventory)
    requested = set(args.family or [])
    selected = {name: stages for name, stages in families.items() if not requested or name in requested}
    if requested:
        missing = sorted(requested - set(selected))
        if missing:
            raise SystemExit("requested source families not found: " + ", ".join(missing))

    with zipfile.ZipFile(args.obb) as obb:
        recovered = [recover_family(name, selected[name], obb) for name in sorted(selected)]

    catalog = load_catalog(args.player_cars)
    catalog_by_prefab = {str(record.get("prefab", "")): record for record in catalog if record.get("prefab")}
    for family in recovered:
        family["catalog"] = catalog_by_prefab.get(family["family"])

    payload = {
        "format_version": 1,
        "source": {
            "kind": "carx_drift_vehicle_profiles",
            "obb": args.obb.name,
            "inventory": args.inventory.name,
            "player_cars": args.player_cars.name if args.player_cars else None,
        },
        "summary": {
            "profile_family_count": len(recovered),
            "complete_five_stage_count": sum(1 for item in recovered if item["complete_five_stage_family"]),
            "catalog_record_count": len(catalog),
        },
        "families": recovered,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(payload["summary"], sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
