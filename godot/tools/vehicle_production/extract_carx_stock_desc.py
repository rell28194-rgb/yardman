#!/usr/bin/env python3
"""Extract CarX stock vehicle fitment/physics data from recovered UnityFS bytes.

The selected CarX bundles contain a printable XML <Desc> payload. This tool
extracts provenance and only the geometry/fitment fields needed to validate a
Yardman vehicle conversion; it does not copy meshes, textures or source media.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import re
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any

XML_RE = re.compile(br'<\?xml[^>]*\?>\s*<Desc\b.*?</Desc>', re.S)
NAME_RE = re.compile(br'[A-Za-z0-9_.-]{4,}Stock')


def number(root: ET.Element, path: str) -> float:
    node = root.find(path)
    if node is None or node.text is None:
        raise ValueError(f"missing {path}")
    return float(node.text.strip())


def tyre(root: ET.Element, path: str) -> dict[str, Any]:
    node = root.find(path)
    if node is None:
        raise ValueError(f"missing {path}")
    def value(name: str) -> float:
        child = node.find(name)
        if child is None or child.text is None:
            raise ValueError(f"missing {path}/{name}")
        return float(child.text.strip())
    return {
        "width_mm": value("width"),
        "profile_percent": value("profile"),
        "rim_in": value("discDiam"),
    }


def extract(path: Path) -> dict[str, Any]:
    source = path.read_bytes()
    raw = gzip.decompress(source) if path.suffix.lower() == ".gz" else source
    match = XML_RE.search(raw)
    if match is None:
        raise ValueError("no embedded CarX <Desc> XML payload")
    xml_bytes = match.group(0)
    root = ET.fromstring(xml_bytes)
    prefix = raw[max(0, match.start() - 512):match.start()]
    names = [item.decode("utf-8", "ignore") for item in NAME_RE.findall(prefix)]
    stock_name = names[-1] if names else ""

    front_z = number(root, "frontBaseZ")
    rear_z = number(root, "rearBaseZ")
    bounds = {
        "center_m": [
            number(root, "carXDesc/weight/bounds/center/x"),
            number(root, "carXDesc/weight/bounds/center/y"),
            number(root, "carXDesc/weight/bounds/center/z"),
        ],
        "size_m": [
            number(root, "carXDesc/weight/bounds/size/x"),
            number(root, "carXDesc/weight/bounds/size/y"),
            number(root, "carXDesc/weight/bounds/size/z"),
        ],
    }
    result = {
        "format_version": 1,
        "tool": "yardman_carx_stock_desc_extract",
        "source_file": path.name,
        "source_bytes": len(source),
        "source_sha256": hashlib.sha256(source).hexdigest(),
        "payload_sha256": hashlib.sha256(xml_bytes).hexdigest(),
        "stock_name": stock_name,
        "bounds": bounds,
        "base_y_m": number(root, "baseY"),
        "front_track_m": number(root, "frontBaseWidth"),
        "rear_track_m": number(root, "rearBaseWidth"),
        "front_axle_z_m": front_z,
        "rear_axle_z_m": rear_z,
        "wheelbase_m": abs(front_z - rear_z),
        "front_tyre": tyre(root, "carXDesc/frontTyre"),
        "rear_tyre": tyre(root, "carXDesc/rearTyre"),
        "front_camber_deg": number(root, "carXDesc/frontSuspension/camber"),
        "rear_camber_deg": number(root, "carXDesc/rearSuspension/camber"),
        "front_steering_lock_deg": number(root, "carXDesc/frontSuspension/frontLock"),
    }
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        result = extract(args.source)
        ok = bool(result["stock_name"])
        result["pass"] = ok
    except Exception as exc:
        result = {
            "format_version": 1,
            "tool": "yardman_carx_stock_desc_extract",
            "source_file": args.source.name,
            "error": str(exc),
            "pass": False,
        }
    text = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding="utf-8")
    print(text, end="")
    return 0 if result.get("pass") else 1


if __name__ == "__main__":
    raise SystemExit(main())
