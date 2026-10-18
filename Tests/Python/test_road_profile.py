import math
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "godot" / "tools"))

from road_profile import smooth_network_profiles


def max_grade(path):
    result = 0.0
    for a, b in zip(path, path[1:]):
        run = math.hypot(float(b[0]) - float(a[0]), float(b[2]) - float(a[2]))
        if run >= 0.25:
            result = max(result, abs((float(b[1]) - float(a[1])) / run) * 100.0)
    return result


class RoadProfileTests(unittest.TestCase):
    def _network(self):
        rough = [
            (0.0, 100.0, 0.0),
            (16.0, 112.0, 0.0),
            (32.0, 96.0, 0.0),
            (48.0, 110.0, 0.0),
            (64.0, 100.0, 0.0),
        ]
        return {
            "edges": {
                "road": {"id": "road", "flags": 0, "path": list(rough), "length_m": 0.0},
                "bridge": {"id": "bridge", "flags": 2, "path": list(rough), "length_m": 0.0},
            },
            "tiles": {
                (0, 0): [
                    [0.0, 0.0, 16.0, 0.0, 6.0, 0, 0, "road", 0, 100.0, 112.0, []],
                    [16.0, 0.0, 32.0, 0.0, 6.0, 0, 0, "road", 1, 112.0, 96.0, []],
                    [32.0, 0.0, 48.0, 0.0, 6.0, 0, 0, "road", 2, 96.0, 110.0, []],
                    [48.0, 0.0, 64.0, 0.0, 6.0, 0, 0, "road", 3, 110.0, 100.0, []],
                ],
            },
            "anchor_roads": {
                "Kingston": {"road_edge_id": "road", "road_position": rough[2]},
            },
            "stats": {},
        }

    def test_terrain_spacing_drives_bounded_deck_refinement(self):
        network = self._network()
        original_road = list(network["edges"]["road"]["path"])
        original_bridge = list(network["edges"]["bridge"]["path"])
        original_max = max_grade(original_road)

        stats = smooth_network_profiles(network, terrain_spacing_m=64.0)
        refined = network["edges"]["road"]["path"]

        self.assertEqual(refined[0], original_road[0])
        self.assertEqual(refined[-1], original_road[-1])
        self.assertEqual(network["edges"]["bridge"]["path"], original_bridge)
        self.assertLess(max_grade(refined), original_max)
        for index in range(1, len(refined) - 1):
            self.assertLessEqual(abs(refined[index][1] - original_road[index][1]), 6.400001)
        self.assertAlmostEqual(stats["profile_adjustment_limit_m"], 6.4)
        self.assertEqual(stats["profile_passes"], 12)
        self.assertAlmostEqual(stats["profile_blend"], 0.75)
        self.assertAlmostEqual(stats["profile_terrain_spacing_m"], 64.0)
        self.assertEqual(stats["profile_structural_edges_skipped"], 1)
        self.assertIn("not surveyed", network["edges"]["road"]["elevation_profile"])

        # The streamed road centreline must use the same refined Y as the graph.
        for record in network["tiles"][(0, 0)]:
            segment_index = int(record[8])
            self.assertAlmostEqual(record[9], refined[segment_index][1])
            self.assertAlmostEqual(record[10], refined[segment_index + 1][1])
        self.assertEqual(tuple(network["anchor_roads"]["Kingston"]["road_position"]), refined[2])

    def test_invalid_terrain_spacing_fails_closed(self):
        for value in (0.0, -1.0, math.inf, math.nan):
            with self.assertRaises(ValueError):
                smooth_network_profiles(self._network(), terrain_spacing_m=value)


if __name__ == "__main__":
    unittest.main()
