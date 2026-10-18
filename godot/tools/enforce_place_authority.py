#!/usr/bin/env python3
"""Remove guessed place geography from Yardman's runtime place index.

The source compiler preserves diagnostics for records that cannot be placed by an
OSM admin-level-6 polygon. This pass makes that distinction enforceable at runtime:
nearest-capital assignments are removed from the runtime tiles and retained only
as unresolved source evidence; synthetic fallback-capital records are discarded.
"""
from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import tempfile

GUESSED_ASSIGNMENTS = {"nearest_capital_fallback"}
SYNTHETIC_ASSIGNMENTS = {"canonical_capital_fallback"}


def enforce_manifest(manifest: dict) -> dict:
    tiles = manifest.get("tiles", {})
    if not isinstance(tiles, dict):
        raise ValueError("place manifest tiles must be a dictionary")

    unresolved = []
    dropped_synthetic = []
    clean_tiles = {}
    kinds = Counter()
    parishes = Counter()
    assignments = Counter()

    for tile_key in sorted(tiles):
        records = tiles[tile_key]
        if not isinstance(records, list):
            raise ValueError(f"place tile {tile_key} must be a list")
        clean = []
        for raw in records:
            if not isinstance(raw, dict):
                raise ValueError(f"place tile {tile_key} contains a non-record")
            record = dict(raw)
            assignment = str(record.get("parish_assignment", ""))
            source = str(record.get("source", ""))
            if assignment in SYNTHETIC_ASSIGNMENTS or source.startswith("fallback/"):
                dropped_synthetic.append(record)
                continue
            if assignment in GUESSED_ASSIGNMENTS:
                record["parish"] = ""
                record["parish_assignment"] = "unresolved_admin_boundary"
                unresolved.append(record)
                continue
            parish = str(record.get("parish", ""))
            if not parish:
                # An unresolved record must not leak into runtime tiles under an
                # unrecognised label. Preserve it only as audit evidence.
                record["parish_assignment"] = assignment or "unresolved_admin_boundary"
                unresolved.append(record)
                continue
            clean.append(record)
            kinds[str(record.get("kind", ""))] += 1
            parishes[parish] += 1
            assignments[str(record.get("parish_assignment", "unknown"))] += 1
        if clean:
            clean_tiles[tile_key] = clean

    result = dict(manifest)
    result["tiles"] = clean_tiles
    result["unresolved_places"] = sorted(
        unresolved,
        key=lambda record: (str(record.get("name", "")).casefold(), str(record.get("source", ""))),
    )
    result["authority_cleanup"] = {
        "policy": "runtime place parish must come from OSM admin_level=6 polygon containment; guessed nearest-capital assignments are audit-only; synthetic capital records are forbidden",
        "unresolved_source_records": len(unresolved),
        "dropped_synthetic_records": len(dropped_synthetic),
        "dropped_synthetic_sources": sorted(str(record.get("source", "")) for record in dropped_synthetic),
    }
    stats = dict(result.get("stats", {}))
    stats.update({
        "places": sum(len(records) for records in clean_tiles.values()),
        "tiles": len(clean_tiles),
        "by_kind": dict(sorted(kinds.items())),
        "by_parish": dict(sorted(parishes.items())),
        "parish_assignment": dict(sorted(assignments.items())),
        "unresolved_source_records": len(unresolved),
        "dropped_synthetic_records": len(dropped_synthetic),
    })
    result["stats"] = stats
    return result


def enforce_file(path: Path) -> dict:
    manifest = json.loads(path.read_text(encoding="utf-8"))
    cleaned = enforce_manifest(manifest)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False) as stream:
        json.dump(cleaned, stream, indent=2, sort_keys=True)
        stream.write("\n")
        temporary = Path(stream.name)
    temporary.replace(path)
    return cleaned


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    args = parser.parse_args()
    cleaned = enforce_file(args.manifest)
    audit = cleaned["authority_cleanup"]
    print(
        "YARDMAN_PLACE_AUTHORITY_PASS runtime_places=%d unresolved=%d dropped_synthetic=%d"
        % (
            cleaned["stats"]["places"],
            audit["unresolved_source_records"],
            audit["dropped_synthetic_records"],
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
