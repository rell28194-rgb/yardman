import copy
import math
import unittest

from godot.tools.road_profile import smooth_network_profiles


class RoadProfileTests(unittest.TestCase):
    def _network(self):
        paved_path = [(0.0, 10.0, 0.0), (10.0, 12.0, 0.0), (20.0, 10.0, 0.0)]
        bridge_path = [(0.0, 5.0, 20.0), (10.0, 9.0, 20.0), (20.0, 5.0, 20.0)]
        return {
            "edges": {
                "road": {"id": "road", "flags": 0, "path": list(paved_path)},
                "bridge": {"id": "bridge", "flags": 2, "path": list(bridge_path)},
            },
            "tiles": {
                (0, 0): [
                    [0.0, 0.0, 10.0, 0.0, 7.0, 0, 0, "road", 0, 10.0, 12.0,
                     [[0.0, 10.0, -3.5], [0.0, 10.0, 3.5], [10.0, 12.0, 3.5], [10.0, 12.0, -3.5]]],
                    [10.0, 0.0, 20.0, 0.0, 7.0, 0, 0, "road", 1, 12.0, 10.0,
                     [[10.0, 12.0, -3.5], [10.0, 12.0, 3.5], [20.0, 10.0, 3.5], [20.0, 10.0, -3.5]]],
                    [0.0, 20.0, 10.0, 20.0, 7.0, 0, 2, "bridge", 0, 5.0, 9.0,
                     [[0.0, 5.0, 16.5], [0.0, 5.0, 23.5], [10.0, 9.0, 23.5], [10.0, 9.0, 16.5]]],
                ],
            },
            "anchor_roads": {
                "Kingston": {"road_edge_id": "road", "road_position": paved_path[1]},
            },
            "stats": {},
        }

    def test_bounded_smoothing_preserves_junctions_and_raw_terrain_polygon(self):
        network = self._network()
        original_polygon = copy.deepcopy(network["tiles"][(0, 0)][0][11])
        bridge_original = list(network["edges"]["bridge"]["path"])
        stats = smooth_network_profiles(network, max_adjustment_m=0.45, passes=2, blend=0.55)

        path = network["edges"]["road"]["path"]
        self.assertEqual(path[0], (0.0, 10.0, 0.0))
        self.assertEqual(path[-1], (20.0, 10.0, 0.0))
        self.assertAlmostEqual(path[1][1], 11.55, places=6)
        self.assertLessEqual(abs(path[1][1] - 12.0), 0.45 + 1e-9)
        self.assertEqual(network["edges"]["bridge"]["path"], bridge_original)
        self.assertEqual(network["tiles"][(0, 0)][0][11], original_polygon)
        self.assertAlmostEqual(network["tiles"][(0, 0)][0][10], 11.55, places=6)
        self.assertAlmostEqual(network["tiles"][(0, 0)][1][9], 11.55, places=6)
        self.assertAlmostEqual(network["anchor_roads"]["Kingston"]["road_position"][1], 11.55, places=6)
        self.assertEqual(stats["profile_smoothed_vertices"], 1)
        self.assertEqual(stats["profile_structural_edges_skipped"], 1)
        self.assertAlmostEqual(stats["profile_max_adjustment_m"], 0.45, places=6)
        self.assertEqual(stats["profile_grade_segments"], 2)
        self.assertAlmostEqual(stats["profile_grade_max_pct"], 15.5, places=4)
        self.assertAlmostEqual(stats["profile_grade_p99_pct"], 15.5, places=4)
        self.assertEqual(stats["profile_grade_over_20pct_segments"], 0)
        self.assertEqual(stats["profile_grade_worst_edge"], "road")
        self.assertIn(stats["profile_grade_worst_segment"], (0, 1))

    def test_grade_diagnostics_surface_extreme_non_structural_segments(self):
        network = {
            "edges": {
                "mountain": {
                    "id": "mountain",
                    "flags": 0,
                    "path": [(0.0, 0.0, 0.0), (10.0, 4.0, 0.0)],
                },
                "structure": {
                    "id": "structure",
                    "flags": 4,
                    "path": [(0.0, 0.0, 20.0), (10.0, 20.0, 20.0)],
                },
            },
            "tiles": {},
            "anchor_roads": {},
            "stats": {},
        }
        stats = smooth_network_profiles(network)
        self.assertEqual(stats["profile_grade_segments"], 1)
        self.assertAlmostEqual(stats["profile_grade_max_pct"], 40.0, places=4)
        self.assertEqual(stats["profile_grade_over_20pct_segments"], 1)
        self.assertEqual(stats["profile_grade_over_30pct_segments"], 1)
        self.assertEqual(stats["profile_grade_worst_edge"], "mountain")
        self.assertEqual(stats["profile_grade_worst_segment"], 0)
        self.assertEqual(stats["profile_structural_edges_skipped"], 1)

    def test_invalid_policy_fails_closed(self):
        network = self._network()
        for kwargs in (
            {"max_adjustment_m": -0.1},
            {"max_adjustment_m": math.inf},
            {"passes": -1},
            {"blend": -0.1},
            {"blend": 1.1},
        ):
            with self.assertRaises(ValueError):
                smooth_network_profiles(copy.deepcopy(network), **kwargs)

    def test_short_edges_remain_unchanged(self):
        network = {"edges": {"short": {"flags": 0, "path": [(0.0, 2.0, 0.0), (5.0, 3.0, 0.0)]}},
                   "tiles": {}, "anchor_roads": {}, "stats": {}}
        original = list(network["edges"]["short"]["path"])
        stats = smooth_network_profiles(network)
        self.assertEqual(network["edges"]["short"]["path"], original)
        self.assertEqual(stats["profile_smoothed_vertices"], 0)
        self.assertEqual(stats["profile_grade_segments"], 1)
        self.assertAlmostEqual(stats["profile_grade_max_pct"], 20.0, places=4)
        self.assertEqual(stats["profile_grade_over_20pct_segments"], 0)


if __name__ == "__main__":
    unittest.main()