#!/usr/bin/env python3
"""Recover source-authentic CarX customization tables for Yardman vehicles.

This reads the original Unity 2018 sharedassets0 TextAssets directly from a
verified CarX APK and the exhaustive NDJSON inventory. It does not execute or
patch CarX. Output preserves exact source IDs, lock/cost metadata, prefab refs,
material parameters, and tuning-controller ranges so Yardman can reimplement
source behavior instead of guessing from a hero mesh.
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
from pathlib import Path
from typing import Any

TABLES = (
    "PlayerCars",
    "WheelTires",
    "CarColors",
    "GlassColors",
    "SmokeColors",
    "WheelCapDictionaryXML",
    "WheelRimColorsDictionaryXML",
    "WheelSpokeColorsDictionaryXML",
    "Profiles",
    "CarProfileParameters",
)

OPTION_TABLES = {
    "WheelTires": "wheel_tires",
    "CarColors": "paint_colors",
    "GlassColors": "glass_colors",
    "SmokeColors": "smoke_colors",
    "WheelCapDictionaryXML": "wheel_caps",
    "WheelRimColorsDictionaryXML": "rim_colors",
    "WheelSpokeColorsDictionaryXML": "spoke_colors",
}


def split_index(name: str) -> int:
    match = re.search(r"\.split(\d+)$", name)
    return int(match.group(1)) if match else -1


def load_sharedassets0(apk: Path) -> bytes:
    with zipfile.ZipFile(apk) as archive:
        parts = [
            name for name in archive.namelist()
            if name.startswith("assets/bin/Data/sharedassets0.assets.split")
        ]
        if not parts:
            raise ValueError("APK has no sharedassets0 split files")
        parts.sort(key=split_index)
        expected = list(range(len(parts)))
        actual = [split_index(name) for name in parts]
        if actual != expected:
            raise ValueError(f"sharedassets0 split sequence is not contiguous: {actual}")
        return b"".join(archive.read(name) for name in parts)


def inventory_records(path: Path) -> dict[str, dict[str, Any]]:
    found: dict[str, dict[str, Any]] = {}
    with gzip.open(path, "rt", encoding="utf-8", errors="replace") as stream:
        for line in stream:
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if record.get("type") != "TextAsset" or record.get("file") != "sharedassets0.assets":
                continue
            name = str(record.get("name") or "")
            if name in TABLES:
                found[name] = record
    missing = sorted(set(TABLES) - set(found))
    if missing:
        raise ValueError("missing TextAsset inventory records: " + ", ".join(missing))
    return found


def extract_xml(shared: bytes, record: dict[str, Any]) -> tuple[str, str]:
    start = int(record["byte_start"])
    size = int(record["byte_size"])
    raw = shared[start:start + size]
    digest = hashlib.sha256(raw).hexdigest()
    if digest != str(record.get("sha256") or ""):
        raise ValueError(f"inventory object SHA mismatch for {record.get('name')}")
    xml_start = raw.find(b"<?xml")
    if xml_start < 0:
        raise ValueError(f"no XML declaration in {record.get('name')}")
    xml_end = raw.rfind(b">")
    if xml_end < xml_start:
        raise ValueError(f"no XML terminator in {record.get('name')}")
    return raw[xml_start:xml_end + 1].decode("utf-8"), digest


def scalar(value: str | None) -> Any:
    text = (value or "").strip()
    if text.lower() == "true":
        return True
    if text.lower() == "false":
        return False
    if re.fullmatch(r"-?\d+", text):
        try:
            return int(text)
        except ValueError:
            pass
    if re.fullmatch(r"-?(?:\d+\.\d*|\d*\.\d+)(?:[eE][+-]?\d+)?", text):
        try:
            return float(text)
        except ValueError:
            pass
    return text


def element(node: ET.Element) -> dict[str, Any]:
    result: dict[str, Any] = {"tag": node.tag}
    if node.attrib:
        result["attributes"] = {key: scalar(value) for key, value in node.attrib.items()}
    text = (node.text or "").strip()
    if text:
        result["text"] = scalar(text)
    children = list(node)
    if children:
        result["children"] = [element(child) for child in children]
    return result


def player_car(root: ET.Element, car_id: int) -> ET.Element:
    for node in root.iter("PlayerCar"):
        if int(node.attrib.get("id", -1)) == car_id:
            return node
    raise ValueError(f"PlayerCar id {car_id} not found")


def car_options(root: ET.Element, car_id: int) -> list[dict[str, Any]]:
    return [element(node) for node in root.iter() if node.attrib.get("carId") == str(car_id)]


def profile_options(root: ET.Element, car_id: int) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for profile in root.iter("PlayerCarProfile"):
        ids = [int((child.text or "-1").strip()) for parent in profile.findall("carId") for child in list(parent)]
        if car_id not in ids:
            continue
        controllers: list[dict[str, Any]] = []
        for controller in profile.findall("./dynoInfo/controllers/CarProfileController"):
            controllers.append(element(controller))
        result.append({
            "id": int(profile.attrib.get("id", -1)),
            "name": profile.attrib.get("name", ""),
            "asset": profile.attrib.get("asset", ""),
            "identifier": profile.attrib.get("identifier", ""),
            "cost": profile.attrib.get("cost", ""),
            "coins_factor": scalar(profile.attrib.get("coinsFactor")),
            "default_locked": scalar(profile.attrib.get("defaultLocked")),
            "sort": scalar(profile.attrib.get("sort")),
            "setup_traction_control": scalar(profile.attrib.get("setupTractionControl")),
            "controllers": controllers,
        })
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--apk", required=True, type=Path)
    parser.add_argument("--inventory", required=True, type=Path)
    parser.add_argument("--car-id", type=int, required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    shared = load_sharedassets0(args.apk)
    records = inventory_records(args.inventory)
    roots: dict[str, ET.Element] = {}
    evidence: dict[str, Any] = {}
    for name, record in records.items():
        xml_text, object_sha = extract_xml(shared, record)
        roots[name] = ET.fromstring(xml_text)
        evidence[name] = {
            "path_id": record.get("path_id"),
            "object_sha256": object_sha,
            "xml_sha256": hashlib.sha256(xml_text.encode("utf-8")).hexdigest(),
        }

    car_node = player_car(roots["PlayerCars"], args.car_id)
    catalog = element(car_node)
    payload: dict[str, Any] = {
        "format_version": 1,
        "source": {
            "apk": args.apk.name,
            "inventory": args.inventory.name,
            "sharedassets0_sha256": hashlib.sha256(shared).hexdigest(),
            "tables": evidence,
        },
        "car_id": args.car_id,
        "catalog": catalog,
        "options": {},
        "profiles": profile_options(roots["Profiles"], args.car_id),
        "profile_parameters": [element(node) for node in roots["CarProfileParameters"].iter("CarProfileParameterMeta")],
    }
    for table_name, output_name in OPTION_TABLES.items():
        payload["options"][output_name] = car_options(roots[table_name], args.car_id)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    summary = {key: len(value) for key, value in payload["options"].items()}
    summary["profiles"] = len(payload["profiles"])
    print(json.dumps(summary, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
