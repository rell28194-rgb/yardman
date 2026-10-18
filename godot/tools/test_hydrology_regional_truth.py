#!/usr/bin/env python3
from hydrology_regional_truth import resolve_regional_morphology


def main() -> None:
    assert resolve_regional_morphology([]).status == "blocked"
    assert resolve_regional_morphology(["parish:st_elizabeth"]).status == "blocked"

    low = resolve_regional_morphology(["WRA:black_river_lowland_wetland"])
    assert low.status == "approved" and low.morphology_family == "lowland_wetland"

    steep = resolve_regional_morphology(["mgd:blue_john_crow_steep_mountain_terrain"])
    assert steep.status == "approved" and steep.morphology_family == "steep_wet_mountain"

    conflict = resolve_regional_morphology([
        "wra:black_river_lowland_wetland",
        "wra:blue_john_crow_steep_wet_drainage",
    ])
    assert conflict.status == "blocked"
    assert conflict.reason == "conflicting_regional_morphology_evidence"

    duplicate = resolve_regional_morphology([
        "WRA:black_river_lowland_wetland",
        "nepa:black_river_morass_wetland",
    ])
    assert duplicate.status == "approved" and duplicate.morphology_family == "lowland_wetland"

    print("hydrology regional truth regression: PASS")


if __name__ == "__main__":
    main()
