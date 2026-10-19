import math
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "godot" / "tools"))

from build_hydrology import channel_seed_depth_m, parse_width_m, registered_segment_key, segment_grade_permille, split_segment_by_tile
from hydrology_truth_pack import segment_key


class HydrologyGeometryTests(unittest.TestCase):
    def test_segment_splits_exactly_at_positive_tile_seam(self):
        pieces = split_segment_by_tile((4090.0, 100.0), (4102.0, 100.0), 4096.0)
        self.assertEqual(len(pieces), 2)
        self.assertEqual(pieces[0][0], (0, 0)); self.assertEqual(pieces[1][0], (1, 0))
        self.assertAlmostEqual(pieces[0][2][0], 4096.0); self.assertEqual(pieces[0][2], pieces[1][1])

    def test_segment_splits_exactly_at_negative_tile_seam(self):
        pieces = split_segment_by_tile((-4102.0, -10.0), (-4090.0, -10.0), 4096.0)
        self.assertEqual(len(pieces), 2); self.assertEqual(pieces[0][0], (-2, -1)); self.assertEqual(pieces[1][0], (-1, -1))
        self.assertAlmostEqual(pieces[0][2][0], -4096.0); self.assertEqual(pieces[0][2], pieces[1][1])

    def test_diagonal_crossing_splits_at_both_axis_seams(self):
        pieces = split_segment_by_tile((4090.0, 4090.0), (4102.0, 4102.0), 4096.0)
        self.assertEqual(len(pieces), 2); self.assertEqual(pieces[0][0], (0, 0)); self.assertEqual(pieces[1][0], (1, 1))
        self.assertEqual(pieces[0][2], pieces[1][1]); self.assertEqual(pieces[0][2], (4096.0, 4096.0))

    def test_zero_length_segment_is_rejected(self):
        self.assertEqual(split_segment_by_tile((1.0, 2.0), (1.0, 2.0), 4096.0), [])

    def test_explicit_width_is_preserved_and_bounded(self):
        self.assertEqual(parse_width_m("12.5 m", "river"), 12.5); self.assertEqual(parse_width_m("999", "river"), 200.0); self.assertEqual(parse_width_m("0.1", "stream"), 0.5)

    def test_class_fallbacks_are_deterministic(self):
        self.assertEqual(parse_width_m(None, "river"), 18.0); self.assertEqual(parse_width_m("unknown", "stream"), 5.0); self.assertTrue(math.isfinite(parse_width_m(None, "ditch")))

    def test_dem_grade_is_signed_and_scale_independent(self):
        self.assertAlmostEqual(segment_grade_permille((0.0, 0.0), (100.0, 0.0), 10.0, 5.0), -50.0)
        self.assertAlmostEqual(segment_grade_permille((0.0, 0.0), (0.0, 100.0), 5.0, 10.0), 50.0)
        self.assertEqual(segment_grade_permille((1.0, 1.0), (1.0, 1.0), 5.0, 9.0), 0.0)

    def test_channel_seed_depth_is_bounded_and_class_specific(self):
        self.assertEqual(channel_seed_depth_m("river", 200.0), 2.5)
        self.assertGreater(channel_seed_depth_m("river", 18.0), channel_seed_depth_m("stream", 5.0))
        self.assertLessEqual(channel_seed_depth_m("ditch", 200.0), 0.5); self.assertGreater(channel_seed_depth_m("stream", 0.5), 0.0)

    def test_compiler_segment_identity_matches_truth_pack_contract(self):
        args = (-3, 11, "w987654", -4096.0, 123.4567894, -4000.25, 222.0000004)
        self.assertEqual(registered_segment_key(*args), segment_key(*args))
        self.assertEqual(registered_segment_key(*args), "-3:11:w987654:-4096.000000:123.456789:-4000.250000:222.000000")

    def test_segment_identity_changes_across_tile_or_source(self):
        base = registered_segment_key(0, 0, "w1", 1.0, 2.0, 3.0, 4.0)
        self.assertNotEqual(base, registered_segment_key(1, 0, "w1", 1.0, 2.0, 3.0, 4.0))
        self.assertNotEqual(base, registered_segment_key(0, 0, "w2", 1.0, 2.0, 3.0, 4.0))


if __name__ == "__main__":
    unittest.main()
