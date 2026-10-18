#!/usr/bin/env python3
"""Provenance-safe spatial evidence attachment for Yardman hydrology.

This module attaches evidence to registered hydrology segments only when an
upstream GIS join supplies a spatially specific authoritative feature. Broad
context (parish, basin, generic WMU, land-cover/geology labels) is retained for
reporting but cannot authorize destructive terrain morphology.
"""
from __future__ import annotations

from dataclasses import asdict, dataclass
import math


@dataclass(frozen=True)
class SpatialEvidence:
    source: str
    source_feature_id: str
    layer: str
    mapped_unit: str
    intersection_fraction: float
    evidence_token: str
    authorizes_morphology: bool
    geometry_valid: bool = True
    geometry_repaired: bool = False
    segment_length_m: float = 0.0
    intersection_length_m: float = 0.0

    def to_dict(self) -> dict:
        return asdict(self)


# Exact mapped-unit contracts. Do not add parish/basin-wide aliases here.
AUTHORITATIVE_UNITS = {
    ("wra", "wmu", "black river lower morass"): "wra:black_river_lower_morass_wmu",
    ("nepa", "wetland", "black river morass"): "nepa:black_river_morass_wetland",
    ("wra", "drainage_context", "blue/john crow steep wet drainage"): "wra:blue_john_crow_steep_wet_drainage",
    ("mgd", "terrain_context", "blue/john crow steep mountain terrain"): "mgd:blue_john_crow_steep_mountain_terrain",
}

CONTEXT_LAYERS = {"parish", "basin", "protected_area", "land_cover", "geology"}


def _norm(value: object) -> str:
    return " ".join(str(value or "").strip().lower().split())


def _safe_fraction(value: object) -> float:
    """Return a finite [0, 1] overlap fraction; invalid GIS numerics become zero."""
    try:
        fraction = float(value)
    except (TypeError, ValueError):
        return 0.0
    if not math.isfinite(fraction):
        return 0.0
    return max(0.0, min(1.0, fraction))


def _safe_nonnegative(value: object) -> float:
    """Return a finite non-negative GIS length; malformed numerics fail closed."""
    try:
        number = float(value)
    except (TypeError, ValueError):
        return 0.0
    if not math.isfinite(number) or number < 0.0:
        return 0.0
    return number


def attach_spatial_evidence(
    *,
    source: str,
    source_feature_id: str,
    layer: str,
    mapped_unit: str,
    intersection_fraction: float,
    geometry_valid: bool = True,
    geometry_repaired: bool = False,
    segment_length_m: float = 0.0,
    intersection_length_m: float = 0.0,
) -> SpatialEvidence:
    """Convert a real GIS intersection into a provenance-bearing evidence record.

    Authorization requires an exact approved mapped-unit contract, a concrete
    source feature, positive overlap, and valid unrepaired source geometry.
    Geometry repaired upstream may still be retained for audit/context, but it
    cannot authorize destructive terrain morphology until separately reviewed.
    Optional metric lengths are retained to make segment-to-polygon joins
    auditable; impossible length relationships fail closed.
    """
    src = _norm(source)
    lyr = _norm(layer)
    unit = _norm(mapped_unit)
    fid = str(source_feature_id or "").strip()
    fraction = _safe_fraction(intersection_fraction)
    seg_len = _safe_nonnegative(segment_length_m)
    hit_len = _safe_nonnegative(intersection_length_m)
    valid = bool(geometry_valid)
    repaired = bool(geometry_repaired)

    # If metric provenance is supplied, it must describe a possible line/polygon
    # intersection. A hit longer than its source segment indicates a broken join.
    lengths_consistent = not (seg_len > 0.0 and hit_len > seg_len + 1e-6)

    token = AUTHORITATIVE_UNITS.get((src, lyr, unit), "")
    authorizes = bool(
        fid
        and fraction > 0.0
        and token
        and valid
        and not repaired
        and lengths_consistent
    )

    # Broad contextual overlays are never excavation permission by themselves.
    if lyr in CONTEXT_LAYERS:
        authorizes = False
        token = ""

    return SpatialEvidence(
        source=src,
        source_feature_id=fid,
        layer=lyr,
        mapped_unit=unit,
        intersection_fraction=fraction,
        evidence_token=token,
        authorizes_morphology=authorizes,
        geometry_valid=valid,
        geometry_repaired=repaired,
        segment_length_m=seg_len,
        intersection_length_m=hit_len,
    )


def morphology_tokens(records: list[SpatialEvidence] | tuple[SpatialEvidence, ...]) -> tuple[str, ...]:
    """Return only provenance-bearing tokens authorized by real intersections."""
    return tuple(sorted({r.evidence_token for r in records if r.authorizes_morphology and r.evidence_token}))
