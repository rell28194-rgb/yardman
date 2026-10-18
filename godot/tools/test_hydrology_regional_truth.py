#!/usr/bin/env python3
from hydrology_regional_truth import resolve_regional_morphology


def main() -> None:
    assert resolve_regional_morphology([]).status == "blocked"
    assert resolve_regional_morphology(["parish:st_elizabeth"]).status == "blocked"
    assert resolve_regional_morphology(["basin:black_river"]).status == "blocked"
    assert resolve_regional_morphology(["wmu:23_black_river"]).status == "blocked"
    assert resolve_regional_morphology(["protected_area:black_river"]).status == "blocked"
    assert resolve_regional_morphology(["land_cover:wetland"]).status == "blocked"
    assert resolve_regional_morphology(["geology:limestone"]).status == "blocked"

    low = resolve_regional_morphology(["WRA:black_river_lower_morass_wmu"])
    assert low.status == "approved" and low.morphology_family == "lowland_wetland"

    legacy_low = resolve_regional_morphology(["WRA:black_river_lowland_wetland"])
    assert legacy_low.status == "approved" and legacy_low.morphology_family == "lowland_wetland"

    steep = resolve_regional_morphology(["mgd:blue_john_crow_steep_mountain_terrain"])
    assert steep.status == "approved" and steep.morphology_family == "steep_wet_mountain"

    conflict = resolve_regional_morphology([
        "wra:black_river_lower_morass_wmu",
        "wra:blue_john_crow_steep_wet_drainage",
    ])
    assert conflict.status == "blocked"
    assert conflict.reason == "conflicting_regional_morphology_evidence"

    corroborated = resolve_regional_morphology([
        "WRA:black_river_lower_morass_wmu",
        "nepa:black_river_morass_wetland",
        "parish:st_elizabeth",
        "basin:black_river",
    ])
    assert corroborated.status == "approved" and corroborated.morphology_family == "lowland_wetland"

    print("hydrology regional truth regression: PASS")


if __name__ == "__main__":
    main()
