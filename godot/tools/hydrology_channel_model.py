#!/usr/bin/env python3
"""Evidence gate for Yardman terrain-embedded hydrology.

This module intentionally does not mutate the DEM. It converts registered
hydrology records into explicit channel candidates and prevents an inferred
width/depth seed from silently becoming geographic truth. A later terrain stage
may consume ``approved`` candidates only when stronger source evidence exists.
"""
from __future__ import annotations

from dataclasses import dataclass, asdict


@dataclass(frozen=True)
class ChannelCandidate:
    waterway: str
    width_m: float
    depth_m: float
    half_width_m: float
    bank_transition_m: float
    grade_permille: float
    status: str
    reason: str
    width_source: str
    depth_source: str

    def to_dict(self) -> dict:
        return asdict(self)


def build_channel_candidate(
    *,
    waterway: str,
    width_m: float,
    depth_m: float,
    grade_permille: float,
    width_source: str,
    depth_source: str,
    morphology_source: str | None = None,
) -> ChannelCandidate:
    """Return a conservative terrain-channel candidate with an evidence gate.

    ``inferred_seed`` depths are never approved for carving by themselves.
    Approval requires explicit morphology evidence (survey/cross-section,
    authoritative engineered-drain record, or an evidence-backed regional
    morphology override). This keeps OSM/DEM registration factual while making
    the later terrain mutation path auditable.
    """
    width = max(0.5, min(200.0, float(width_m)))
    depth = max(0.0, min(12.0, float(depth_m)))
    grade = max(-2000.0, min(2000.0, float(grade_permille)))
    half_width = width * 0.5
    # Transition is geometry scaffolding, not a claim about surveyed bank width.
    bank_transition = max(1.0, min(30.0, width * 0.75))

    evidence = (morphology_source or "").strip().lower()
    approved_sources = {
        "authoritative_cross_section",
        "authoritative_engineered_drain",
        "evidence_backed_regional_override",
    }
    if evidence in approved_sources and depth_source != "inferred_seed":
        status = "approved"
        reason = evidence
    elif evidence in approved_sources:
        status = "candidate_only"
        reason = "depth_is_inferred_seed"
    else:
        status = "candidate_only"
        reason = "morphology_evidence_required"

    return ChannelCandidate(
        waterway=waterway,
        width_m=round(width, 3),
        depth_m=round(depth, 3),
        half_width_m=round(half_width, 3),
        bank_transition_m=round(bank_transition, 3),
        grade_permille=round(grade, 3),
        status=status,
        reason=reason,
        width_source=width_source,
        depth_source=depth_source,
    )
