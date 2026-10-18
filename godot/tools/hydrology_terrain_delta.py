#!/usr/bin/env python3
"""Deterministic, evidence-gated terrain deltas for Yardman hydrology.

This module converts an already-approved TerrainOperation into a bounded
cross-section delta. It never upgrades evidence and never emits excavation for
blocked operations. Regional morphology is explicit: steep wet mountain
channels and lowland/wetland channels use different evidence-backed profile
families instead of a national generic trench.
"""
from __future__ import annotations

from dataclasses import asdict, dataclass

from hydrology_terrain_plan import TerrainOperation


@dataclass(frozen=True)
class TerrainDeltaProfile:
    status: str
    reason: str
    morphology_family: str
    bed_half_width_m: float
    bank_transition_m: float
    max_excavation_m: float
    shoulder_slope_ratio: float

    def to_dict(self) -> dict:
        return asdict(self)


def build_terrain_delta_profile(
    operation: TerrainOperation,
    *,
    morphology_family: str,
) -> TerrainDeltaProfile:
    """Return a deterministic cross-section profile for an approved operation.

    Supported families are deliberately narrow. ``steep_wet_mountain`` is for
    evidence-backed steep wet drainage such as Blue/John Crow Mountain contexts;
    ``lowland_wetland`` is for evidence-backed low-gradient wetland/lowland
    contexts such as Black River. Selecting a family is not itself evidence:
    callers must already have an approved TerrainOperation.
    """
    family = (morphology_family or "").strip().lower()
    if operation.status != "approved" or operation.action == "none":
        return TerrainDeltaProfile("blocked", "terrain_operation_not_approved", family or "none", 0.0, 0.0, 0.0, 0.0)

    if family == "steep_wet_mountain":
        bed_half = max(0.5, operation.channel_width_m * 0.35)
        transition = max(1.0, min(operation.bank_transition_m, operation.channel_width_m * 0.55))
        slope_ratio = 0.75
    elif family == "lowland_wetland":
        bed_half = max(0.5, operation.channel_width_m * 0.48)
        transition = max(2.0, min(30.0, max(operation.bank_transition_m, operation.channel_width_m * 1.25)))
        slope_ratio = 2.5
    else:
        return TerrainDeltaProfile("blocked", "unsupported_or_unproven_morphology_family", family or "none", 0.0, 0.0, 0.0, 0.0)

    # Never deepen beyond the approved morphology depth.
    excavation = max(0.0, operation.channel_depth_m)
    return TerrainDeltaProfile(
        "approved",
        "approved_operation_and_regional_morphology",
        family,
        round(bed_half, 3),
        round(transition, 3),
        round(excavation, 3),
        slope_ratio,
    )


def sample_cross_section_delta(profile: TerrainDeltaProfile, offset_m: float) -> float:
    """Return DEM delta (metres, <= 0) at lateral offset from channel centre."""
    if profile.status != "approved" or profile.max_excavation_m <= 0.0:
        return 0.0
    x = abs(float(offset_m))
    if x <= profile.bed_half_width_m:
        return -profile.max_excavation_m
    outer = profile.bed_half_width_m + profile.bank_transition_m
    if x >= outer:
        return 0.0
    t = (x - profile.bed_half_width_m) / profile.bank_transition_m
    return -profile.max_excavation_m * (1.0 - t)
