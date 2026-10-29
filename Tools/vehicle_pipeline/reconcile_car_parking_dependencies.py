#!/usr/bin/env python3
"""Build per-car dependency manifests from preserved Car Parking catalog evidence.

The production checkpoint already contains one record per recovered `car<N>`
Addressables bundle with its original Unity container paths. Those paths expose
far more than a hero mesh: car/body/LOD prefabs, body-kit parts, animations,
materials and engine-sound prefabs.

This tool classifies that evidence without pretending a path is a fully decoded
asset. Output is a recovery queue and dependency map, not an acceptance claim.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any


def classify(paths: list[str]) -> dict[str, list[str]]:
    def take(predicate):
        return sorted(path for path in paths if predicate(path))

    lower = {path: path.lower() for path in paths}
    return {
        "car_prefab": take(lambda p: bool(re.search(r"/Prefabs/cars/car\d+\.prefab$", p, re.I))),
        "body_prefab": take(lambda p: bool(re.search(r"/Prefabs/body/b\d+\.prefab$", p, re.I))),
        "lod_prefab": take(lambda p: "/prefabs/body/_lod/" in lower[p] and p.lower().endswith(".prefab")),
        "interior_prefab": take(lambda p: bool(re.search(r"/Prefabs/body/i\d+\.prefab$", p, re.I))),
        "bodykit_config": take(lambda p: "/prefabs/bodykits/" in lower[p] and p.lower().endswith(".asset")),
        "front_bumpers": take(lambda p: "/prefabs/bodykits/" in lower[p] and "/fbumper" in lower[p] and p.lower().endswith(".prefab")),
        "rear_bumpers": take(lambda p: "/prefabs/bodykits/" in lower[p] and "/rbumper" in lower[p] and p.lower().endswith(".prefab")),
        "skirts": take(lambda p: "/prefabs/bodykits/" in lower[p] and "/skirts" in lower[p] and p.lower().endswith(".prefab")),
        "hoods": take(lambda p: "/prefabs/bodykits/" in lower[p] and "/hood" in lower[p] and p.lower().endswith(".prefab")),
        "fenders": take(lambda p: "/prefabs/bodykits/" in lower[p] and "/fender" in lower[p] and p.lower().endswith(".prefab")),
        "spoilers_or_wings": take(lambda p: "/prefabs/bodykits/" in lower[p] and any(token in lower[p] for token in ("/spoiler", "/wing")) and p.lower().endswith(".prefab")),
        "engine_sound_prefab": take(lambda p: "/sounds/enginesounds/" in lower[p] and p.lower().endswith(".prefab")),
        "animations": take(lambda p: p.lower().endswith(".anim")),
        "materials": take(lambda p: p.lower().endswith(".mat")),
        "textures": take(lambda p: p.lower().endswith((".png", ".jpg", ".jpeg", ".tga", ".psd", ".exr", ".dds"))),
        "other_prefabs": take(lambda p: p.lower().endswith(".prefab") and "/prefabs/" in lower[p]),
    }


def model_hint(record: dict[str, Any]) -> list[str]:
    return sorted({str(value).strip() for value in record.get("model_directories", []) if str(value).strip()})


def inferred_name(car_id: int, hints: list[str]) -> str | None:
    if not hints:
        return None
    # Only strip an exact leading numeric directory id. Keep the rest verbatim as
    # source evidence; do not normalize brands/models into a guessed identity.
    for hint in hints:
        match = re.match(rf"^{car_id}\s*[-_ ]?\s*(.+)$", hint)
        if match and match.group(1).strip():
            return match.group(1).strip()
    return hints[0]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--containers", required=True, type=Path)
    parser.add_argument("--catalog-ids", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    records = json.loads(args.containers.read_text(encoding="utf-8"))
    catalog = json.loads(args.catalog_ids.read_text(encoding="utf-8"))
    if not isinstance(records, list) or not isinstance(catalog, dict):
        raise SystemExit("unexpected source JSON shape")

    cars: list[dict[str, Any]] = []
    category_counts: dict[str, int] = {}
    catalog_resolved = 0
    hint_only = 0
    unresolved = 0

    for record in sorted(records, key=lambda item: int(item["car_id"])):
        car_id = int(record["car_id"])
        paths = [str(path) for path in record.get("container_paths", [])]
        deps = classify(paths)
        names = catalog.get(str(car_id), [])
        names = [str(name) for name in names if str(name).strip()]
        hints = model_hint(record)
        if names:
            identity = {"state": "catalog_resolved", "names": names, "evidence": "catalog_model_directory_ids"}
            catalog_resolved += 1
        else:
            hint = inferred_name(car_id, hints)
            if hint:
                identity = {"state": "model_directory_hint", "names": [hint], "evidence": "bundle_model_directory"}
                hint_only += 1
            else:
                identity = {"state": "unresolved", "names": [], "evidence": None}
                unresolved += 1

        counts = {key: len(value) for key, value in deps.items()}
        for key, count in counts.items():
            if count:
                category_counts[key] = category_counts.get(key, 0) + 1

        cars.append({
            "car_id": car_id,
            "bundle": record.get("bundle"),
            "identity": identity,
            "model_directory_hints": hints,
            "dependency_counts": counts,
            "dependencies": deps,
            "raw_container_path_count": len(paths),
            "status": "DISCOVERED",
            "acceptance": "not_claimed",
        })

    payload = {
        "format_version": 1,
        "source": {
            "containers": args.containers.name,
            "catalog_ids": args.catalog_ids.name,
            "meaning": "preserved Car Parking Addressables container-path evidence",
        },
        "summary": {
            "car_bundle_count": len(cars),
            "catalog_resolved_count": catalog_resolved,
            "model_directory_hint_only_count": hint_only,
            "fully_unresolved_identity_count": unresolved,
            "cars_with_dependency_category": dict(sorted(category_counts.items())),
        },
        "cars": cars,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(payload["summary"], sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
