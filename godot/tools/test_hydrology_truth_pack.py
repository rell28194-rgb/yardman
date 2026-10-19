#!/usr/bin/env python3
from hydrology_spatial_evidence import SpatialEvidence
from hydrology_truth_pack import build_truth_pack, segment_key


def evidence(token: str, feature: str = "f1") -> SpatialEvidence:
    family_unit = {
        "wra:black_river_lower_morass_wmu": ("wra", "Lower Morass"),
        "wra:blue_john_crow_steep_wet_drainage": ("wra", "Blue John Crow steep wet drainage"),
    }
    source, unit = family_unit[token]
    return SpatialEvidence(source, feature, "hydrology_region", unit, 0.8, token, True)


def main() -> None:
    key_a = segment_key(1, 2, "w10", 1, 2, 3, 4)
    key_b = segment_key(1, 2, "w11", 5, 6, 7, 8)
    segments = [
        {"segment_key": key_a, "source_way": "w10", "tile": [1, 2]},
        {"segment_key": key_b, "source_way": "w11", "tile": [1, 2]},
    ]
    pack = build_truth_pack(segments, {key_a: [evidence("wra:black_river_lower_morass_wmu")]})
    assert pack["segments"][0]["decision"]["status"] == "approved"
    assert pack["segments"][0]["decision"]["morphology_family"] == "lowland_wetland"
    assert pack["segments"][1]["decision"]["status"] == "blocked"
    assert pack["metrics"]["segments_approved"] == 1
    assert pack["metrics"]["segments_blocked_no_evidence"] == 1

    conflict = build_truth_pack(segments[:1], {key_a: [
        evidence("wra:black_river_lower_morass_wmu", "low"),
        evidence("wra:blue_john_crow_steep_wet_drainage", "steep"),
    ]})
    assert conflict["segments"][0]["decision"]["reason"] == "conflicting_authoritative_morphology_evidence"
    assert conflict["metrics"]["segments_blocked_conflict"] == 1

    orphan = build_truth_pack(segments[:1], {"not-a-real-segment": [evidence("wra:black_river_lower_morass_wmu")]})
    assert orphan["metrics"]["orphan_evidence_segment_keys"] == 1
    assert orphan["orphan_evidence_segment_keys"] == ["not-a-real-segment"]

    try:
        build_truth_pack([segments[0], segments[0]], {})
    except ValueError:
        pass
    else:
        raise AssertionError("duplicate segment keys must fail closed")
    print("HYDROLOGY_TRUTH_PACK_PASS")


if __name__ == "__main__":
    main()
