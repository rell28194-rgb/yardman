import hashlib
import importlib
import json
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / "godot" / "tools"
sys.path.insert(0, str(TOOLS))

# The integration under test is compiler -> filesystem/manifest -> route pack.
# CRS math is unrelated here, so keep this core gate independent of pyproj.
fake_pyproj = types.ModuleType("pyproj")


class _Transformer:
    @classmethod
    def from_crs(cls, *_args, **_kwargs):
        return cls()

    def transform(self, x, y):
        return float(x), float(y)


fake_pyproj.Transformer = _Transformer
sys.modules["pyproj"] = fake_pyproj

build_jamaica_roads = importlib.import_module("build_jamaica_roads")
road_route_pack = importlib.import_module("road_route_pack")


class GodotRoadRoutePackIntegrationTests(unittest.TestCase):
    def synthetic_network(self):
        return {
            "nodes": {
                "osm:1": {"id": "osm:1", "position": (0.0, 0.0, 0.0), "edges": ["edge:a"]},
                "osm:2": {"id": "osm:2", "position": (10.0, 1.0, 0.0), "edges": ["edge:a"]},
            },
            "edges": {
                "edge:a": {
                    "id": "edge:a",
                    "source_way": "w1",
                    "from": "osm:1",
                    "to": "osm:2",
                    "path": [(0.0, 0.0, 0.0), (10.0, 1.0, 0.0)],
                    "length_m": 10.0,
                    "class": "primary",
                    "class_id": 2,
                    "width_m": 7.2,
                    "lanes": 2,
                    "width_source": "class estimate",
                    "markings_inferred": 1,
                    "surface": "asphalt",
                    "direction": 1,
                    "speed_limit_mps": 13.5,
                    "speed_tag": "48.6 km/h",
                    "bridge": False,
                    "tunnel": False,
                    "layer": "0",
                    "flags": 1,
                    "elevation_source": "unmeasured-flat",
                    "tiles": [],
                }
            },
            "tiles": {},
            "bounds": [0.0, 0.0, 10.0, 1.0],
            "stats": {
                "road_features": 1,
                "source_segments": 1,
                "segments": 0,
                "tiles": 0,
                "graph_nodes": 2,
                "graph_edges": 1,
                "centerline_boundary_crossings": 0,
                "skipped_non_drivable_features": 0,
                "degenerate_segments": 0,
                "by_highway_type": {"primary": 1},
                "parish_anchor_distance_m": {},
            },
            "anchor_roads": {},
        }

    def test_compile_dataset_emits_manifested_route_pack(self):
        network = self.synthetic_network()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "roads.geojson"
            source.write_text(json.dumps({"type": "FeatureCollection", "features": []}), encoding="utf-8")
            output = root / "roads"
            with mock.patch.object(build_jamaica_roads, "build_network", return_value=network):
                manifest = build_jamaica_roads.compile_dataset(
                    source,
                    output,
                    tile_size=4096.0,
                    require_national_coverage=False,
                )

            route_path = output / "graph" / "routes.ymr"
            self.assertTrue(route_path.is_file())
            payload = route_path.read_bytes()
            self.assertEqual(payload, road_route_pack.build_route_pack(network))

            metadata = manifest["graph"]["route_pack"]
            self.assertEqual(metadata["file"], "routes.ymr")
            self.assertEqual(metadata["format"], 1)
            self.assertEqual(metadata["nodes"], 2)
            self.assertEqual(metadata["edges"], 1)
            self.assertEqual(metadata["bytes"], len(payload))
            self.assertEqual(metadata["sha256"], hashlib.sha256(payload).hexdigest())

            persisted = json.loads((output / "manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(persisted["graph"]["route_pack"], metadata)


if __name__ == "__main__":
    unittest.main()
