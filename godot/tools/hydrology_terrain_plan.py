#!/usr/bin/env python3
"""Evidence-gated terrain operation planning for registered Yardman hydrology.

This module is the boundary between hydrology truth and DEM mutation.  It does
not carve terrain itself.  It emits an auditable operation only when channel
morphology is approved and, at a road crossing, the crossing semantics also
explicitly permit that treatment.  Unknown/conflicting crossings and road
tunnels remain non-destructive until stronger clearance/structure evidence is
available.
"""
from __future__ import annotations

from dataclasses import asdict, dataclass

from hydrology_channel_model import ChannelCandidate
from hydrology_crossings import CrossingDecision


@dataclass(frozen=True)
class TerrainOperation:
    status: str
    action: str
    reason: str
    channel_width_m: float
    channel_depth_m: float
    bank_transition_m: float
    crossing_kind: str

    def to_dict(self) -> dict:
        return asdict(self)


def plan_terrain_operation(
    channel: ChannelCandidate,
    crossing: CrossingDecision | None = None,
) -> TerrainOperation:
    """Plan a conservative DEM operation without upgrading weak evidence.

    Away from roads, approved morphology may produce a channel operation. At a
    road crossing, both morphology and crossing structure must be approved.
    Bridges and culverts preserve the approved channel below the road; explicit
    fords preserve it at grade. Road tunnels are deliberately blocked because
    tunnel-cover/clearance evidence is not yet represented by this contract.
    """
    kind = crossing.kind if crossing is not None else "none"
    base = dict(
        channel_width_m=channel.width_m,
        channel_depth_m=channel.depth_m,
        bank_transition_m=channel.bank_transition_m,
        crossing_kind=kind,
    )
    if channel.status != "approved":
        return TerrainOperation("blocked", "none", "channel_morphology_not_approved", **base)

    if crossing is None:
        return TerrainOperation("approved", "incise_registered_channel", "approved_channel_morphology", **base)

    if crossing.status != "approved":
        return TerrainOperation("blocked", "none", "crossing_not_approved", **base)

    if crossing.kind in {"bridge", "culvert"} and crossing.terrain_action == "preserve_channel_below":
        return TerrainOperation("approved", "incise_channel_below_road", f"approved_{crossing.kind}", **base)

    if crossing.kind == "ford" and crossing.terrain_action == "preserve_at_grade_channel":
        return TerrainOperation("approved", "incise_at_grade_ford_channel", "approved_ford", **base)

    if crossing.kind == "road_tunnel":
        return TerrainOperation("blocked", "none", "tunnel_clearance_evidence_required", **base)

    return TerrainOperation("blocked", "none", "unsupported_crossing_treatment", **base)
