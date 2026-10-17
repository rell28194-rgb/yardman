import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "godot" / "tools"))

from build_hydrology_channels import (
    bank_margin_m,
    conservative_bed_height,
    crossing_protection_radius_m,
    visible_intervals,
)


class HydrologyChannelTests(unittest.TestCase):
    def test_bank_margin_scales_but_stays_bounded(self):
        self.assertEqual(bank_margin_m(1.0), 2.5)
        self.assertEqual(bank_margin_m(10.0), 4.0)
        self.assertEqual(bank_margin_m(100.0), 12.0)

    def test_incision_is_below_center_and_capped(self):
        bed = conservative_bed_height(100.0, 101.0, 101.5, 20.0)
        self.assertLess(bed, 100.0)
        self.assertGreaterEqual(bed, 98.5)

    def test_existing_valley_relief_is_preserved(self):
        bed = conservative_bed_height(95.0, 101.0, 100.0, 10.0)
        self.assertLess(bed, 95.0)
        self.assertGreaterEqual(bed, 93.5)

    def test_bad_profile_is_rejected(self):
        with self.assertRaises(ValueError):
            conservative_bed_height(float("nan"), 1.0, 1.0, 5.0)
        with self.assertRaises(ValueError):
            conservative_bed_height(1.0, 1.0, 1.0, 0.0)

    def test_single_crossing_circle_splits_channel(self):
        pieces = visible_intervals((0.0, 0.0), (100.0, 0.0), [(50.0, 0.0, 10.0)])
        self.assertEqual(len(pieces), 2)
        self.assertAlmostEqual(pieces[0][0], 0.0)
        self.assertAlmostEqual(pieces[0][1], 0.4)
        self.assertAlmostEqual(pieces[1][0], 0.6)
        self.assertAlmostEqual(pieces[1][1], 1.0)

    def test_off_segment_crossing_does_not_clip(self):
        pieces = visible_intervals((0.0, 0.0), (100.0, 0.0), [(50.0, 50.0, 5.0)])
        self.assertEqual(pieces, [(0.0, 1.0)])

    def test_overlapping_protection_zones_merge(self):
        pieces = visible_intervals(
            (0.0, 0.0), (100.0, 0.0),
            [(45.0, 0.0, 10.0), (55.0, 0.0, 10.0)],
        )
        self.assertEqual(len(pieces), 2)
        self.assertAlmostEqual(pieces[0][1], 0.35)
        self.assertAlmostEqual(pieces[1][0], 0.65)

    def test_protection_radius_accounts_for_road_and_water_width(self):
        narrow = crossing_protection_radius_m("service", 5.0)
        major = crossing_protection_radius_m("primary", 20.0)
        self.assertGreaterEqual(narrow, 7.0)
        self.assertGreater(major, narrow)


if __name__ == "__main__":
    unittest.main()
