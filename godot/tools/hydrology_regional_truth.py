#!/usr/bin/env python3
"""Evidence-gated regional morphology registry for Yardman hydrology.

This module never assigns morphology from parish name alone. A segment must carry
explicit regional evidence tokens supplied by authoritative/project GIS joins.
The registry only maps those approved evidence tokens to terrain-delta families.
Unknown, ambiguous, or conflicting evidence remains non-destructive downstream.
"""
from __future__ import annotations

from dataclasses import asdict, dataclass


@dataclass(frozen=True)
class RegionalMorphologyDecision:
    status: str
    morphology_family: str
    reason: str
    evidence_tokens: tuple[str, ...]

    def to_dict(self) -> dict:
        return asdict(self)


# Narrow first tranche: intentionally no national/parish fallback.
# Tokens are contracts for upstream GIS joins, not claims that every feature in
# the named region has this morphology.
EVIDENCE_FAMILY = {
    "wra:black_river_lowland_wetland": "lowland_wetland",
    "nepa:black_river_morass_wetland": "lowland_wetland",
    "wra:blue_john_crow_steep_wet_drainage": "steep_wet_mountain",
    "mgd:blue_john_crow_steep_mountain_terrain": "steep_wet_mountain",
}


def resolve_regional_morphology(evidence_tokens: list[str] | tuple[str, ...]) -> RegionalMorphologyDecision:
    tokens = tuple(sorted({str(t).strip().lower() for t in evidence_tokens if str(t).strip()}))
    matched = {EVIDENCE_FAMILY[t] for t in tokens if t in EVIDENCE_FAMILY}
    if not matched:
        return RegionalMorphologyDecision("blocked", "none", "no_approved_regional_morphology_evidence", tokens)
    if len(matched) != 1:
        return RegionalMorphologyDecision("blocked", "none", "conflicting_regional_morphology_evidence", tokens)
    family = next(iter(matched))
    return RegionalMorphologyDecision("approved", family, "approved_regional_evidence", tokens)
