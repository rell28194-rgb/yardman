#!/usr/bin/env python3
"""Build an exhaustive Yardman vehicle-family/dependency queue from Unity inventories.

Input is one or more NDJSON/NDJSON.GZ object inventories produced by Yardman's
existing Unity inventory tooling. The script deliberately favors recall over
precision: vehicle-looking serialized files are queued for dependency/identity
closure instead of being silently discarded. Porsche-specific candidates are
marked rights-excluded, not converted.
"""
from __future__ import annotations

import argparse
import gzip
import json
import re
from collections import Counter, defaultdict
from pathlib import Path
from typing import Iterable

BODY = re.compile(r"(?i)(^body(?:$|[_ -])|body[_ -]?lod|bodyh$|bodyl$|chassis|carbody|car_merged)")
WHEEL = re.compile(r"(?i)(wheel|rim|tyre|tire)")
INTERIOR = re.compile(r"(?i)(interior|seat|steering|dashboard|shifter|hbrake|handbrake|cockpit)")
LIGHT = re.compile(r"(?i)(headlight|stoplight|taillight|tail_light|lights?rear|brake.?light|lights?front)")
PAINT = re.compile(r"(?i)(paint|livery|carbon|glass|rubber|stitch)")
VEHICLE = re.compile(r"(?i)(car|vehicle|auto|racer|rival|traffic|police|ambulance|truck|van|bus|taxi|camper)")
PORSCHE = re.compile(r"(?i)(porsche|\b911\b|\b992\b|cayman|boxster|panamera|macan|taycan)")
GENERIC_NAMES = {
    "body", "bodyh", "bodyl", "body_h", "body_l", "body_lod0", "body_lod1", "body_lod2",
    "wheel", "rim", "tire", "tyre", "interior", "car", "cars", "vehicle", "chassis",
    "engineaudiosource", "gearaudiosource", "turboaudiosource", "driverroot", "cameras",
}


def open_text(path: Path):
    return gzip.open(path, "rt", encoding="utf-8", errors="replace") if path.suffix == ".gz" else path.open("r", encoding="utf-8", errors="replace")


def iter_objects(paths: Iterable[Path]):
    for path in paths:
        with open_text(path) as handle:
            for line_number, line in enumerate(handle, 1):
                if not line.strip():
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError as exc:
                    raise ValueError(f"{path}:{line_number}: {exc}") from exc
                yield path, obj


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("inventory", type=Path, nargs="+")
    parser.add_argument("--source-id", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--include-low-confidence", action="store_true")
    args = parser.parse_args()

    files = defaultdict(lambda: {
        "objects": 0,
        "types": Counter(),
        "names": set(),
        "signals": Counter(),
        "porsche_hits": set(),
    })
    total_objects = 0

    for _path, obj in iter_objects(args.inventory):
        total_objects += 1
        serialized_file = str(obj.get("file") or "<unknown>")
        name = str(obj.get("name") or "")
        typ = str(obj.get("type") or "")
        row = files[serialized_file]
        row["objects"] += 1
        row["types"][typ] += 1
        if name:
            row["names"].add(name)
        if BODY.search(name): row["signals"]["body"] += 1
        if WHEEL.search(name): row["signals"]["wheel"] += 1
        if INTERIOR.search(name): row["signals"]["interior"] += 1
        if LIGHT.search(name): row["signals"]["light"] += 1
        if PAINT.search(name): row["signals"]["material_role"] += 1
        if VEHICLE.search(name): row["signals"]["vehicle_name"] += 1
        if PORSCHE.search(name): row["porsche_hits"].add(name)

    queue = []
    rights_excluded = []
    skipped = 0
    for serialized_file in sorted(files):
        row = files[serialized_file]
        signals = row["signals"]
        signal_kinds = sum(1 for key in ("body", "wheel", "interior", "light", "material_role", "vehicle_name") if signals[key])
        has_mesh = row["types"]["Mesh"] > 0
        high_confidence = bool(signals["body"] and (signals["wheel"] or signals["interior"] or signals["light"] or has_mesh))
        medium_confidence = bool(signal_kinds >= 3 or (signals["vehicle_name"] and has_mesh))
        low_confidence = bool(signal_kinds >= 2)
        if not high_confidence and not medium_confidence and not (args.include_low_confidence and low_confidence):
            skipped += 1
            continue

        names = sorted(row["names"])
        hints = [n for n in names if n.lower() not in GENERIC_NAMES and not n.lower().endswith("audiosource")]
        hints.sort(key=lambda n: (0 if VEHICLE.search(n) else 1, len(n), n.lower()))
        entry = {
            "family_id": f"{args.source_id}:{serialized_file}",
            "serialized_file": serialized_file,
            "classification": "vehicle_family_or_dependency_candidate",
            "confidence": "high" if high_confidence else "medium" if medium_confidence else "low",
            "object_count": row["objects"],
            "type_counts": dict(sorted(row["types"].items())),
            "signals": dict(sorted(signals.items())),
            "identity_hints": hints[:40],
            "state": "DISCOVERED",
            "next_state": "SOURCE_EXTRACTED",
        }
        if row["porsche_hits"]:
            entry["state"] = "PORSCHE_RIGHTS_EXCLUDED"
            entry["porsche_hits"] = sorted(row["porsche_hits"])
            rights_excluded.append(entry)
        else:
            queue.append(entry)

    report = {
        "format_version": 1,
        "tool": "yardman_discover_unity_fleet",
        "source_id": args.source_id,
        "input_files": [str(p) for p in args.inventory],
        "total_inventory_objects": total_objects,
        "serialized_files_seen": len(files),
        "migration_queue_count": len(queue),
        "porsche_rights_excluded_count": len(rights_excluded),
        "non_vehicle_files_not_queued": skipped,
        "migration_queue": queue,
        "rights_excluded": rights_excluded,
        "policy": {
            "selection": "recall-first; queue ambiguous vehicle families/dependencies for closure rather than silently dropping them",
            "porsche": "mark source-specific Porsche candidates excluded and do not convert them",
            "promotion": "discovery is not integration acceptance"
        }
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({k: report[k] for k in ("source_id", "total_inventory_objects", "serialized_files_seen", "migration_queue_count", "porsche_rights_excluded_count", "non_vehicle_files_not_queued")}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
