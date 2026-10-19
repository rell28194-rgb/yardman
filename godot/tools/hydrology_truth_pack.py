#!/usr/bin/env python3
"""Attach reconciled regional morphology evidence to registered hydrology segments.

This module is intentionally non-destructive. It produces an auditable sidecar
that terrain rasterization may consume later; blocked or missing evidence never
becomes terrain permission.
"""
from __future__ import annotations

from dataclasses import asdict

from hydrology_evidence_reconciliation import reconcile_segment_evidence, reconciliation_metrics
from hydrology_spatial_evidence import SpatialEvidence


def segment_key(tile_x: int, tile_z: int, source_way: str, ax: float, az: float, bx: float, bz: float) -> str:
    """Stable key for one DEM-registered, tile-split source segment."""
    return f"{int(tile_x)}:{int(tile_z)}:{source_way}:{ax:.6f}:{az:.6f}:{bx:.6f}:{bz:.6f}"


def build_truth_pack(segments: list[dict], evidence_by_segment: dict[str, list[SpatialEvidence]]) -> dict:
    """Reconcile evidence for every registered segment and retain provenance."""
    output = []
    decisions = []
    seen = set()
    for segment in segments:
        key = str(segment["segment_key"])
        if key in seen:
            raise ValueError(f"duplicate registered hydrology segment key: {key}")
        seen.add(key)
        decision = reconcile_segment_evidence(evidence_by_segment.get(key, []))
        decisions.append(decision)
        output.append({
            "segment_key": key,
            "source_way": str(segment.get("source_way", "")),
            "tile": list(segment.get("tile", [])),
            "decision": decision.to_dict(),
        })

    orphan_keys = sorted(set(evidence_by_segment) - seen)
    metrics = reconciliation_metrics(decisions)
    metrics["orphan_evidence_segment_keys"] = len(orphan_keys)
    return {
        "format": 1,
        "policy": "evidence-gated; blocked decisions are never terrain mutation permission",
        "metrics": metrics,
        "orphan_evidence_segment_keys": orphan_keys,
        "segments": output,
    }
