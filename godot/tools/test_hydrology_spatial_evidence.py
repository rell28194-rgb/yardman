#!/usr/bin/env python3
from hydrology_spatial_evidence import attach_spatial_evidence, morphology_tokens, unique_authorized_evidence


def make_wra(**kwargs):
    args = dict(source="wra", source_feature_id="wmu-26-lm", layer="wmu", mapped_unit="Black River Lower Morass", intersection_fraction=0.75)
    args.update(kwargs)
    return attach_spatial_evidence(**args)


def test_exact_wra_lower_morass_join_authorizes():
    r = make_wra()
    assert r.authorizes_morphology
    assert morphology_tokens([r]) == ("wra:black_river_lower_morass_wmu",)


def test_zero_intersection_never_authorizes():
    r = make_wra(intersection_fraction=0.0)
    assert not r.authorizes_morphology


def test_invalid_numeric_intersections_fail_closed():
    for value in (float("nan"), float("inf"), float("-inf"), "not-a-number", None):
        r = make_wra(intersection_fraction=value)
        assert r.intersection_fraction == 0.0
        assert not r.authorizes_morphology


def test_finite_intersection_is_clamped_for_auditability():
    r = make_wra(intersection_fraction=1.2)
    assert r.intersection_fraction == 1.0
    assert r.authorizes_morphology


def test_missing_source_feature_id_never_authorizes():
    assert not make_wra(source_feature_id="").authorizes_morphology


def test_context_only_overlays_cannot_authorize():
    for layer, unit in (("parish", "St Elizabeth"), ("basin", "Black River"), ("land_cover", "wetland"), ("geology", "limestone"), ("protected_area", "Black River")):
        r = attach_spatial_evidence(source="wra", source_feature_id="ctx-1", layer=layer, mapped_unit=unit, intersection_fraction=1.0)
        assert not r.authorizes_morphology
        assert r.evidence_token == ""


def test_unknown_mapped_unit_is_context_not_permission():
    assert not attach_spatial_evidence(source="wra", source_feature_id="wmu-x", layer="wmu", mapped_unit="Black River", intersection_fraction=1.0).authorizes_morphology


def test_nepa_morass_join_preserves_provenance():
    r = attach_spatial_evidence(source="nepa", source_feature_id="wetland-brm-001", layer="wetland", mapped_unit="Black River Morass", intersection_fraction=0.42)
    assert r.authorizes_morphology
    assert r.source_feature_id == "wetland-brm-001"
    assert morphology_tokens([r]) == ("nepa:black_river_morass_wetland",)


def test_invalid_geometry_cannot_authorize():
    assert not make_wra(intersection_fraction=0.8, geometry_valid=False).authorizes_morphology


def test_repaired_geometry_is_audit_only_until_reviewed():
    r = attach_spatial_evidence(source="nepa", source_feature_id="wetland-brm-repaired", layer="wetland", mapped_unit="Black River Morass", intersection_fraction=0.6, geometry_valid=True, geometry_repaired=True)
    assert not r.authorizes_morphology
    assert r.evidence_token == "nepa:black_river_morass_wetland"


def test_impossible_intersection_length_fails_closed():
    r = make_wra(intersection_fraction=0.9, segment_length_m=100.0, intersection_length_m=120.0)
    assert not r.authorizes_morphology
    assert not r.topology_consistent


def test_consistent_metric_provenance_authorizes():
    r = make_wra(intersection_fraction=0.75, segment_length_m=100.0, intersection_length_m=75.0)
    assert r.authorizes_morphology
    assert r.topology_consistent


def test_boundary_only_touch_never_authorizes():
    r = make_wra(intersection_fraction=0.01, segment_length_m=100.0, intersection_length_m=0.0, join_topology="boundary_touch")
    assert not r.authorizes_morphology
    assert not r.topology_consistent


def test_point_touch_never_authorizes_even_with_fraction_bug():
    r = make_wra(intersection_fraction=0.25, join_topology="point_touch")
    assert not r.authorizes_morphology


def test_multipart_line_overlap_can_authorize():
    r = make_wra(intersection_fraction=0.4, segment_length_m=50.0, intersection_length_m=20.0, join_topology="multipart_line_overlap")
    assert r.authorizes_morphology


def test_sliver_fraction_length_mismatch_fails_closed():
    r = make_wra(intersection_fraction=0.30, segment_length_m=100.0, intersection_length_m=0.01)
    assert not r.authorizes_morphology
    assert not r.topology_consistent


def test_tiny_but_self_consistent_real_overlap_is_not_arbitrarily_discarded():
    r = make_wra(intersection_fraction=0.0001, segment_length_m=100.0, intersection_length_m=0.01)
    assert r.authorizes_morphology


def test_duplicate_authoritative_feature_is_deduplicated_deterministically():
    a = make_wra(intersection_fraction=0.4)
    b = make_wra(intersection_fraction=0.7)
    unique = unique_authorized_evidence([a, b])
    assert len(unique) == 1
    assert unique[0].intersection_fraction == 0.7
    assert morphology_tokens([a, b]) == ("wra:black_river_lower_morass_wmu",)


def test_distinct_authoritative_features_remain_distinct_for_audit():
    a = make_wra(source_feature_id="wmu-a", intersection_fraction=0.5)
    b = make_wra(source_feature_id="wmu-b", intersection_fraction=0.5)
    assert len(unique_authorized_evidence([a, b])) == 2


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    for test in tests:
        test()
    print(f"hydrology spatial evidence: {len(tests)} tests passed")
