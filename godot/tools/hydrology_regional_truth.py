#!/usr/bin/env python3
"""Evidence-gated regional morphology registry for Yardman hydrology.

This module never assigns morphology from parish name alone. A segment must carry
explicit regional evidence tokens supplied by authoritative/project GIS joins.
The registry only maps those approved evidence tokens to terrain-delta families.
Unknown, ambiguous, or conflicting evidence remains non-destructive downstream.

Source contracts are intentionally spatially specific. A token names an
authoritative mapped unit/context; it is not permission to apply the morphology
across an entire parish, basin, protected area, or named region.
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
    # WRA National Water Resources Master Plan 2022, Black River Basin map:
    # Lower Black River -> Lower Morass is explicitly mapped as a WMU sub-unit,
    # with swamp/marsh/mangrove among the mapped hydrostratigraphic units.
    "wra:black_river_lower_morass_wmu": "lowland_wetland",
    # NEPA Black River Protected Landscape evidence explicitly identifies the
    # Upper/Lower Morass wetland systems. Requires a spatial protected-area /
    # wetland intersection upstream; the protected-area name alone is not enough.
    "nepa:black_river_morass_wetland": "lowland_wetland",
    # Legacy aliases retained so existing compiled truth packs remain readable.
    "wra:black_river_lowland_wetland": "lowland_wetland",
    # Blue/John Crow tokens remain evidence contracts pending authoritative GIS
    # spatial joins; neither parish membership nor protected-area membership is
    # sufficient by itself to authorize steep-channel terrain mutation.
    "wra:blue_john_crow_steep_wet_drainage": "steep_wet_mountain",
    "mgd:blue_john_crow_steep_mountain_terrain": "steep_wet_mountain",
}

# Context labels that are useful for reporting/joins but must never authorize a
# destructive morphology decision on their own.
CONTEXT_ONLY_PREFIXES = (
    "parish:",
    "basin:",
    "wmu:",
    "protected_area:",
    "land_cover:",
    "geology:",
)


def resolve_regional_morphology(evidence_tokens: list[str] | tuple[str, ...]) -> RegionalMorphologyDecision:
    tokens = tuple(sorted({str(t).strip().lower() for t in evidence_tokens if str(t).strip()}))
    matched = {EVIDENCE_FAMILY[t] for t in tokens if t in EVIDENCE_FAMILY}
    if not matched:
        return RegionalMorphologyDecision("blocked", "none", "no_approved_regional_morphology_evidence", tokens)
    if len(matched) != 1:
        return RegionalMorphologyDecision("blocked", "none", "conflicting_regional_morphology_evidence", tokens)
    family = next(iter(matched))
    return RegionalMorphologyDecision("approved", family, "approved_regional_evidence", tokens)
