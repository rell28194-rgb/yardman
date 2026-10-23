#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import sys

TOOLS = pathlib.Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))

from work_zone_compile import compile_work_zones


class IdentityTransformer:
    def transform(self, lon: float, lat: float):
        return lon, lat


class HeightSampler:
    def __call__(self, x: float, z: float) -> float:
        return 25.0 + x * 0.01 - z * 0.02


def main() -> int:
    features = [
        {
            "type": "Feature",
            "id": "w100",
            "properties": {"highway": "construction", "construction": "primary", "access": "no"},
            "geometry": {"type": "LineString", "coordinates": [[10.0, 10.0], [70.0, 10.0]]},
        },
        {
            "type": "Feature",
            "id": "w200",
            "properties": {"highway": "residential"},
            "geometry": {"type": "LineString", "coordinates": [[0.0, 0.0], [20.0, 0.0]]},
        },
    ]
    payload = compile_work_zones(features, IdentityTransformer(), (0.0, 0.0), 32.0, HeightSampler())
    assert payload["format"] == 1
    assert payload["routing"] is False and payload["collision"] is False
    assert payload["stats"]["source_ways"] == 1
    assert payload["stats"]["source_segments"] == 1
    assert payload["stats"]["tile_pieces"] == 3
    assert payload["stats"]["tiles"] == 3
    assert payload["stats"]["by_construction_type"] == {"primary": 1}
    records = [record for sector in payload["sectors"] for record in sector[2]]
    assert len(records) == 3
    assert {record["source_way"] for record in records} == {"w100"}
    assert {record["construction"] for record in records} == {"primary"}
    assert {record["access"] for record in records} == {"no"}
    assert {record["elevation_source"] for record in records} == {"DEM"}
    # The residential fixture must never leak into the work-zone layer.
    assert all(record["source_way"] != "w200" for record in records)
    # Shared tile-boundary points must stay exact so presentation does not crack.
    ordered = sorted(records, key=lambda record: record["a"][0])
    assert ordered[0]["b"] == ordered[1]["a"]
    assert ordered[1]["b"] == ordered[2]["a"]
    print("YARDMAN_WORK_ZONE_COMPILE_TEST PASS source=1 pieces=3 tiles=3 routing=0 collision=0 dem=1 seams=1")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
