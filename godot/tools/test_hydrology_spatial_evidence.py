#!/usr/bin/env python3
from hydrology_spatial_evidence import attach_spatial_evidence, morphology_tokens


def test_exact_wra_lower_morass_join_authorizes():
    r = attach_spatial_evidence(source="WRA", source_feature_id="wmu-26-lm", layer="wmu", mapped_unit="Black River Lower Morass", intersection_fraction=0.75)
    assert r.authorizes_morphology
    assert morphology_tokens([r]) == ("wra:black_river_lower_morass_wmu",)


def test_zero_intersection_never_authorizes():
    r = attach_spatial_evidence(source="wra", source_feature_id="wmu-26-lm", layer="wmu", mapped_unit="Black River Lower Morass", intersection_fraction=0.0)
    assert not r.authorizes_morphology
    assert morphology_tokens([r]) == ()


def test_invalid_numeric_intersections_fail_closed():
    for value in (float("nan"), float("inf"), float("-inf"), "not-a-number", None):
        r = attach_spatial_evidence(source="wra", source_feature_id="wmu-26-lm", layer="wmu", mapped_unit="Black River Lower Morass", intersection_fraction=value)
        assert r.intersection_fraction == 0.0
        assert not r.authorizes_morphology
        assert morphology_tokens([r]) == ()


def test_finite_intersection_is_clamped_for_auditability():
    r = attach_spatial_evidence(source="wra", source_feature_id="wmu-26-lm", layer="wmu", mapped_unit="Black River Lower Morass", intersection_fraction=1.2)
    assert r.intersection_fraction == 1.0
    assert r.authorizes_morphology


def test_missing_source_feature_id_never_authorizes():
    r = attach_spatial_evidence(source="wra", source_feature_id="", layer="wmu", mapped_unit="Black River Lower Morass", intersection_fraction=0.9)
    assert not r.authorizes_morphology


def test_context_only_overlays_cannot_authorize():
    for layer, unit in (("parish", "St Elizabeth"), ("basin", "Black River"), ("land_cover", "wetland"), ("geology", "limestone"), ("protected_area", "Black River")):
        r = attach_spatial_evidence(source="wra", source_feature_id="ctx-1", layer=layer, mapped_unit=unit, intersection_fraction=1.0)
        assert not r.authorizes_morphology
        assert r.evidence_token == ""


def test_unknown_mapped_unit_is_context_not_permission():
    r = attach_spatial_evidence(source="wra", source_feature_id="wmu-x", layer="wmu", mapped_unit="Black River", intersection_fraction=1.0)
    assert not r.authorizes_morphology


def test_nepa_morass_join_preserves_provenance():
    r = attach_spatial_evidence(source="nepa", source_feature_id="wetland-brm-001", layer="wetland", mapped_unit="Black River Morass", intersection_fraction=0.42)
    assert r.authorizes_morphology
    assert r.source_feature_id == "wetland-brm-001"
    assert r.intersection_fraction == 0.42
    assert morphology_tokens([r]) == ("nepa:black_river_morass_wetland",)


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    for test in tests:
        test()
    print(f"hydrology spatial evidence: {len(tests)} tests passed")
