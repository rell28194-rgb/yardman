#!/usr/bin/env python3
from pathlib import Path
import sys

TOOLS = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))

from build_hydrology_crossings import _culvert_evidence, _ford_evidence, _positive_value


def main() -> int:
    for value in (True, "yes", "true", "1", "ford", "culvert"):
        assert _positive_value(value), value
    for value in (False, None, "", "no", "false", "0", "none"):
        assert not _positive_value(value), value

    source = {
        "road_tags": {"w1": {"ford": "yes"}, "w2": {"culvert": "yes"}, "w3": {"ford": "no"}},
        "water_tags": {
            "w10": {"tunnel": "culvert", "waterway": "stream"},
            "w11": {"culvert": "yes", "waterway": "drain"},
            "w12": {"ford": "yes", "waterway": "river"},
        },
        "road_ford_nodes": {
            "w3": [(101, 100.0, 200.0)],
            "w4": [(102, 500.0, 500.0)],
        },
    }

    found, reason = _ford_evidence(source, "w1", "w99", 0.0, 0.0)
    assert found and reason == "osm:road_way_ford"
    found, reason = _ford_evidence(source, "w99", "w12", 0.0, 0.0)
    assert found and reason == "osm:water_way_ford"
    found, reason = _ford_evidence(source, "w3", "w99", 103.0, 204.0)
    assert found and reason == "osm:ford_node=101"
    found, _ = _ford_evidence(source, "w3", "w99", 107.0, 204.0)
    assert not found, "ford-node evidence must fail outside the 6 m crossing agreement"
    found, _ = _ford_evidence(source, "w4", "w99", 100.0, 200.0)
    assert not found, "a ford node on another road way must not authorize this crossing"

    found, reason = _culvert_evidence(source, "w2", "w99")
    assert found and reason == "osm:road_way_culvert"
    found, reason = _culvert_evidence(source, "w99", "w11")
    assert found and reason == "osm:water_way_culvert"
    found, reason = _culvert_evidence(source, "w99", "w10")
    assert found and reason == "osm:waterway_tunnel=culvert"
    found, _ = _culvert_evidence(source, "w3", "w99")
    assert not found

    print("YARDMAN_CROSSING_SOURCE_EVIDENCE_PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
