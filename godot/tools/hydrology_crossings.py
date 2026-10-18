#!/usr/bin/env python3
"""Evidence-gated road/water crossing classification for Yardman.

This module classifies an already-registered geometric road/water intersection.
It never invents a bridge, culvert or ford. Source road bridge/tunnel/layer
semantics and explicit water-crossing evidence are preserved as provenance so a
later DEM mutation stage can decide whether a channel may pass beneath a road.
"""
from __future__ import annotations

from dataclasses import asdict, dataclass


@dataclass(frozen=True)
class CrossingDecision:
    kind: str
    status: str
    terrain_action: str
    reason: str
    evidence: tuple[str, ...]

    def to_dict(self) -> dict:
        value = asdict(self)
        value["evidence"] = list(self.evidence)
        return value


def _layer(value) -> int:
    try:
        return max(-10, min(10, int(str(value or "0").strip())))
    except ValueError:
        return 0


def classify_crossing(
    *,
    road_bridge: bool = False,
    road_tunnel: bool = False,
    road_layer=0,
    explicit_ford: bool = False,
    explicit_culvert: bool = False,
    engineered_drain_record: bool = False,
) -> CrossingDecision:
    """Classify a registered road/water intersection without inventing works.

    ``terrain_action`` is deliberately conservative. ``preserve_channel_below``
    is allowed only for source-backed grade separation. Culverts require an
    explicit culvert or authoritative engineered-drain record. Fords require an
    explicit ford. Everything else remains unresolved/non-destructive.
    """
    layer = _layer(road_layer)
    evidence: list[str] = []
    if road_bridge:
        evidence.append("osm:road_bridge")
    if road_tunnel:
        evidence.append("osm:road_tunnel")
    if layer:
        evidence.append(f"osm:road_layer={layer}")
    if explicit_ford:
        evidence.append("source:ford")
    if explicit_culvert:
        evidence.append("source:culvert")
    if engineered_drain_record:
        evidence.append("authoritative:engineered_drain")

    # Contradictory structural evidence must not be resolved by guessing.
    structural = int(bool(road_bridge)) + int(bool(road_tunnel)) + int(bool(explicit_ford)) + int(bool(explicit_culvert or engineered_drain_record))
    if structural > 1:
        return CrossingDecision("conflict", "unresolved", "none", "contradictory_crossing_evidence", tuple(evidence))

    if road_bridge:
        return CrossingDecision("bridge", "approved", "preserve_channel_below", "source_backed_bridge", tuple(evidence))
    if road_tunnel:
        return CrossingDecision("road_tunnel", "approved", "preserve_terrain_above_road", "source_backed_road_tunnel", tuple(evidence))
    if explicit_culvert or engineered_drain_record:
        return CrossingDecision("culvert", "approved", "preserve_channel_below", "source_backed_culvert_or_drain", tuple(evidence))
    if explicit_ford:
        return CrossingDecision("ford", "approved", "preserve_at_grade_channel", "source_backed_ford", tuple(evidence))

    # A non-zero layer is useful evidence that the road is grade-separated, but
    # without bridge/tunnel/crossing semantics it is insufficient to identify
    # what physical structure exists at this particular water intersection.
    if layer:
        return CrossingDecision("grade_separation_candidate", "unresolved", "none", "layer_without_crossing_structure", tuple(evidence))
    return CrossingDecision("unknown", "unresolved", "none", "crossing_evidence_required", tuple(evidence))
