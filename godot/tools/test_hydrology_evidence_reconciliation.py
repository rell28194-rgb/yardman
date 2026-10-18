#!/usr/bin/env python3
from hydrology_evidence_reconciliation import reconcile_segment_evidence, reconciliation_metrics
from hydrology_spatial_evidence import attach_spatial_evidence


def evidence(source, feature_id, layer, unit, fraction=0.5):
    return attach_spatial_evidence(
        source=source,
        source_feature_id=feature_id,
        layer=layer,
        mapped_unit=unit,
        intersection_fraction=fraction,
    )


def test_no_authorized_evidence_blocks_mutation():
    d = reconcile_segment_evidence([])
    assert d.status == "blocked"
    assert d.morphology_family == "none"
    assert d.reason == "no_authorized_spatial_morphology_evidence"


def test_corroborating_black_river_sources_approve_one_family():
    records = [
        evidence("wra", "wmu-lm", "wmu", "Black River Lower Morass", 0.8),
        evidence("nepa", "morass-1", "wetland", "Black River Morass", 0.6),
    ]
    d = reconcile_segment_evidence(records)
    assert d.status == "approved"
    assert d.morphology_family == "lowland_wetland"
    assert d.authorized_record_count == 2
    assert len(d.source_feature_keys) == 2


def test_conflicting_authoritative_families_fail_closed():
    records = [
        evidence("wra", "wmu-lm", "wmu", "Black River Lower Morass", 0.8),
        evidence("mgd", "terrain-bjc", "terrain_context", "Blue/John Crow steep mountain terrain", 0.7),
    ]
    d = reconcile_segment_evidence(records)
    assert d.status == "blocked"
    assert d.morphology_family == "none"
    assert d.reason == "conflicting_authoritative_morphology_evidence"
    assert d.authorized_record_count == 2


def test_stronger_overlap_cannot_override_conflict():
    records = [
        evidence("wra", "wmu-lm", "wmu", "Black River Lower Morass", 0.99),
        evidence("mgd", "terrain-bjc", "terrain_context", "Blue/John Crow steep mountain terrain", 0.01),
    ]
    assert reconcile_segment_evidence(records).status == "blocked"


def test_duplicate_feature_does_not_inflate_provenance_count():
    records = [
        evidence("wra", "wmu-lm", "wmu", "Black River Lower Morass", 0.4),
        evidence("wra", "wmu-lm", "wmu", "Black River Lower Morass", 0.7),
    ]
    d = reconcile_segment_evidence(records)
    assert d.status == "approved"
    assert d.authorized_record_count == 1


def test_context_only_records_do_not_create_coverage():
    record = evidence("wra", "parish-1", "parish", "St Elizabeth", 1.0)
    d = reconcile_segment_evidence([record])
    assert d.status == "blocked"
    assert d.authorized_record_count == 0


def test_national_metrics_separate_conflict_from_missing_evidence():
    approved = reconcile_segment_evidence([
        evidence("wra", "wmu-lm", "wmu", "Black River Lower Morass", 0.8),
    ])
    conflict = reconcile_segment_evidence([
        evidence("wra", "wmu-lm", "wmu", "Black River Lower Morass", 0.8),
        evidence("mgd", "terrain-bjc", "terrain_context", "Blue/John Crow steep mountain terrain", 0.7),
    ])
    missing = reconcile_segment_evidence([])
    assert reconciliation_metrics([approved, conflict, missing]) == {
        "segments_total": 3,
        "segments_approved": 1,
        "segments_blocked_no_evidence": 1,
        "segments_blocked_conflict": 1,
    }


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    for test in tests:
        test()
    print(f"hydrology evidence reconciliation: {len(tests)} tests passed")
