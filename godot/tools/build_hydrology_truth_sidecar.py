#!/usr/bin/env python3
"""Build an auditable national hydrology decision sidecar from compiler-owned IDs.

This stage is deliberately non-destructive. It reads the national hydrology
compiler output, preserves each exact registered segment identity, and emits an
explicit reconciliation decision for every segment. Authoritative GIS evidence
may be supplied as JSON records keyed by segment_key; absent evidence stays
blocked and therefore cannot authorize terrain mutation.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from hydrology_spatial_evidence import SpatialEvidence
from hydrology_truth_pack import build_truth_pack


def _evidence(record: dict) -> SpatialEvidence:
    """Deserialize the canonical SpatialEvidence schema without legacy aliases.

    Evidence ingress is fail-closed: authorization is read only from the current
    authorizes_morphology field. Older/unknown field names cannot accidentally
    become terrain authority, while valid geometry/topology provenance survives
    the sidecar round trip unchanged.
    """
    return SpatialEvidence(
        source=str(record.get("source", "")),
        source_feature_id=str(record.get("source_feature_id", "")),
        layer=str(record.get("layer", "")),
        mapped_unit=str(record.get("mapped_unit", "")),
        intersection_fraction=float(record.get("intersection_fraction", 0.0)),
        evidence_token=str(record.get("evidence_token", "")),
        authorizes_morphology=bool(record.get("authorizes_morphology", False)),
        geometry_valid=bool(record.get("geometry_valid", True)),
        geometry_repaired=bool(record.get("geometry_repaired", False)),
        segment_length_m=float(record.get("segment_length_m", 0.0)),
        intersection_length_m=float(record.get("intersection_length_m", 0.0)),
        join_topology=str(record.get("join_topology", "line_overlap")),
        topology_consistent=bool(record.get("topology_consistent", True)),
    )


def load_registered_segments(hydrology_root: Path) -> list[dict]:
    manifest = json.loads((hydrology_root / "manifest.json").read_text(encoding="utf-8"))
    record_format = list(manifest.get("record_format", []))
    required = {"source_way", "segment_key"}
    if not required.issubset(record_format):
        raise ValueError("hydrology compiler output lacks compiler-owned segment identity")
    index = {name: record_format.index(name) for name in required}
    segments: list[dict] = []
    for tile in manifest.get("tiles", []):
        payload = json.loads((hydrology_root / tile["file"]).read_text(encoding="utf-8"))
        tile_id = list(payload.get("tile", [tile.get("x"), tile.get("z")]))
        for record in payload.get("segments", []):
            segments.append({
                "segment_key": str(record[index["segment_key"]]),
                "source_way": str(record[index["source_way"]]),
                "tile": tile_id,
            })
    return segments


def load_evidence(path: Path | None) -> dict[str, list[SpatialEvidence]]:
    if path is None:
        return {}
    payload = json.loads(path.read_text(encoding="utf-8"))
    rows = payload.get("evidence", payload) if isinstance(payload, dict) else payload
    if not isinstance(rows, list):
        raise ValueError("evidence input must be a list or an object containing an evidence list")
    result: dict[str, list[SpatialEvidence]] = {}
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError("authoritative evidence rows must be objects")
        key = str(row.get("segment_key", ""))
        if not key:
            raise ValueError("authoritative evidence row missing segment_key")
        result.setdefault(key, []).append(_evidence(row))
    return result


def build_sidecar(hydrology_root: Path, output_path: Path, evidence_path: Path | None = None) -> dict:
    segments = load_registered_segments(hydrology_root)
    pack = build_truth_pack(segments, load_evidence(evidence_path))
    pack["source_hydrology_manifest"] = str(hydrology_root / "manifest.json")
    pack["terrain_mutation_authority"] = "approved decisions only; blocked/missing/conflict decisions are non-destructive"
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(pack, indent=2, sort_keys=True), encoding="utf-8")
    return pack


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("hydrology_root", type=Path)
    parser.add_argument("output_path", type=Path)
    parser.add_argument("--evidence", type=Path)
    args = parser.parse_args()
    pack = build_sidecar(args.hydrology_root, args.output_path, args.evidence)
    print("YARDMAN_HYDROLOGY_SIDECAR_PASS", json.dumps(pack["metrics"], sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
