import math
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "godot" / "tools"))

from build_hydrology import parse_width_m, split_segment_by_tile


class HydrologyGeometryTests(unittest.TestCase):
    def test_segment_splits_exactly_at_positive_tile_seam(self):
        pieces = split_segment_by_tile((4090.0, 100.0), (4102.0, 100.0), 4096.0)
        self.assertEqual(len(pieces), 2)
        self.assertEqual(pieces[0][0], (0, 0))
        self.assertEqual(pieces[1][0], (1, 0))
        self.assertAlmostEqual(pieces[0][2][0], 4096.0)
        self.assertEqual(pieces[0][2], pieces[1][1])

    def test_segment_splits_exactly_at_negative_tile_seam(self):
        pieces = split_segment_by_tile((-4102.0, -10.0), (-4090.0, -10.0), 4096.0)
        self.assertEqual(len(pieces), 2)
        self.assertEqual(pieces[0][0], (-2, -1))
        self.assertEqual(pieces[1][0], (-1, -1))
        self.assertAlmostEqual(pieces[0][2][0], -4096.0)
        self.assertEqual(pieces[0][2], pieces[1][1])

    def test_diagonal_crossing_splits_at_both_axis_seams(self):
        pieces = split_segment_by_tile((4090.0, 4090.0), (4102.0, 4102.0), 4096.0)
        self.assertEqual(len(pieces), 2)
        self.assertEqual(pieces[0][0], (0, 0))
        self.assertEqual(pieces[1][0], (1, 1))
        self.assertEqual(pieces[0][2], pieces[1][1])
        self.assertEqual(pieces[0][2], (4096.0, 4096.0))

    def test_zero_length_segment_is_rejected(self):
        self.assertEqual(split_segment_by_tile((1.0, 2.0), (1.0, 2.0), 4096.0), [])

    def test_explicit_width_is_preserved_and_bounded(self):
        self.assertEqual(parse_width_m("12.5 m", "river"), 12.5)
        self.assertEqual(parse_width_m("999", "river"), 200.0)
        self.assertEqual(parse_width_m("0.1", "stream"), 0.5)

    def test_class_fallbacks_are_deterministic(self):
        self.assertEqual(parse_width_m(None, "river"), 18.0)
        self.assertEqual(parse_width_m("unknown", "stream"), 5.0)
        self.assertTrue(math.isfinite(parse_width_m(None, "ditch")))


if __name__ == "__main__":
    unittest.main()
