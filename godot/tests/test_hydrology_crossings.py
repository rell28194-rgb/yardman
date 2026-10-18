#!/usr/bin/env python3
from pathlib import Path
import sys

TOOLS = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))

from hydrology_crossings import classify_crossing


def main() -> int:
    bridge = classify_crossing(road_bridge=True, road_layer=1)
    assert bridge.kind == "bridge" and bridge.status == "approved"
    assert bridge.terrain_action == "preserve_channel_below"
    assert "osm:road_bridge" in bridge.evidence

    unknown = classify_crossing()
    assert unknown.status == "unresolved" and unknown.terrain_action == "none"

    layered = classify_crossing(road_layer=1)
    assert layered.kind == "grade_separation_candidate"
    assert layered.status == "unresolved" and layered.terrain_action == "none"

    culvert = classify_crossing(explicit_culvert=True)
    assert culvert.kind == "culvert" and culvert.status == "approved"
    assert culvert.terrain_action == "preserve_channel_below"

    drain = classify_crossing(engineered_drain_record=True)
    assert drain.kind == "culvert" and drain.status == "approved"

    ford = classify_crossing(explicit_ford=True)
    assert ford.kind == "ford" and ford.terrain_action == "preserve_at_grade_channel"

    tunnel = classify_crossing(road_tunnel=True, road_layer=-1)
    assert tunnel.kind == "road_tunnel" and tunnel.terrain_action == "preserve_terrain_above_road"

    conflict = classify_crossing(road_bridge=True, explicit_ford=True)
    assert conflict.kind == "conflict" and conflict.status == "unresolved"
    assert conflict.terrain_action == "none"

    print("YARDMAN_HYDROLOGY_CROSSINGS_PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
