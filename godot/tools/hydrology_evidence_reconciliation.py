#!/usr/bin/env python3
"""Segment-level reconciliation of provenance-safe hydrology morphology evidence.

Individual GIS joins are validated by hydrology_spatial_evidence. This layer
combines those authorized records for one registered hydrology segment without
silently resolving disagreements between authoritative sources. Any conflict
remains non-destructive and retains the contributing provenance for audit.
"""
from __future__ import annotations

from dataclasses import asdict, dataclass

from hydrology_regional_truth import EVIDENCE_FAMILY
from hydrology_spatial_evidence import SpatialEvidence, unique_authorized_evidence


@dataclass(frozen=True)
class SegmentEvidenceDecision:
    status: str
    morphology_family: str
    reason: str
    evidence_tokens: tuple[str, ...]
    source_feature_keys: tuple[str, ...]
    authorized_record_count: int

    def to_dict(self) -> dict:
        return asdict(self)


def reconcile_segment_evidence(
    records: list[SpatialEvidence] | tuple[SpatialEvidence, ...],
) -> SegmentEvidenceDecision:
    """Resolve authorized GIS hits for one hydrology segment.

    No majority vote, source priority, parish fallback, or strongest-overlap rule
    is allowed to resolve a morphology disagreement. Duplicate hits for the same
    authoritative feature are collapsed first; distinct provenance is retained.
    """
    unique = unique_authorized_evidence(records)
    tokens = tuple(sorted({r.evidence_token for r in unique if r.evidence_token}))
    feature_keys = tuple(sorted(f"{r.source}:{r.source_feature_id}:{r.evidence_token}" for r in unique))
    families = {EVIDENCE_FAMILY[t] for t in tokens if t in EVIDENCE_FAMILY}

    if not unique or not families:
        return SegmentEvidenceDecision(
            "blocked", "none", "no_authorized_spatial_morphology_evidence",
            tokens, feature_keys, len(unique),
        )
    if len(families) != 1:
        return SegmentEvidenceDecision(
            "blocked", "none", "conflicting_authoritative_morphology_evidence",
            tokens, feature_keys, len(unique),
        )

    family = next(iter(families))
    return SegmentEvidenceDecision(
        "approved", family, "consistent_authoritative_spatial_evidence",
        tokens, feature_keys, len(unique),
    )


def reconciliation_metrics(
    decisions: list[SegmentEvidenceDecision] | tuple[SegmentEvidenceDecision, ...],
) -> dict[str, int]:
    """Emit focused national counters without converting coverage into permission."""
    metrics = {
        "segments_total": len(decisions),
        "segments_approved": 0,
        "segments_blocked_no_evidence": 0,
        "segments_blocked_conflict": 0,
    }
    for decision in decisions:
        if decision.status == "approved":
            metrics["segments_approved"] += 1
        elif decision.reason == "conflicting_authoritative_morphology_evidence":
            metrics["segments_blocked_conflict"] += 1
        else:
            metrics["segments_blocked_no_evidence"] += 1
    return metrics
