import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))

from build_jamaica_roads import (
    ROAD_FLAG_BRIDGE,
    ROAD_FLAG_ONEWAY,
    ROAD_FLAG_ONEWAY_REVERSE,
    ROAD_FLAG_TUNNEL,
    ROAD_FLAG_UNPAVED,
    road_flags,
)


class RoadDirectionFlagTests(unittest.TestCase):
    def test_explicit_forward_oneway(self):
        flags = road_flags({"highway": "primary", "oneway": "yes"})
        self.assertTrue(flags & ROAD_FLAG_ONEWAY)
        self.assertFalse(flags & ROAD_FLAG_ONEWAY_REVERSE)

    def test_explicit_reverse_oneway_preserves_direction(self):
        flags = road_flags({"highway": "primary", "oneway": "-1"})
        self.assertTrue(flags & ROAD_FLAG_ONEWAY)
        self.assertTrue(flags & ROAD_FLAG_ONEWAY_REVERSE)

    def test_roundabout_is_implicitly_forward_oneway(self):
        flags = road_flags({"highway": "secondary", "junction": "roundabout"})
        self.assertTrue(flags & ROAD_FLAG_ONEWAY)
        self.assertFalse(flags & ROAD_FLAG_ONEWAY_REVERSE)

    def test_motorway_is_implicitly_forward_oneway(self):
        flags = road_flags({"highway": "motorway"})
        self.assertTrue(flags & ROAD_FLAG_ONEWAY)
        self.assertFalse(flags & ROAD_FLAG_ONEWAY_REVERSE)

    def test_explicit_no_overrides_implicit_oneway(self):
        self.assertEqual(road_flags({"highway": "motorway", "oneway": "no"}) & ROAD_FLAG_ONEWAY, 0)
        self.assertEqual(road_flags({"highway": "secondary", "junction": "roundabout", "oneway": "false"}) & ROAD_FLAG_ONEWAY, 0)

    def test_existing_surface_bits_remain_stable(self):
        flags = road_flags({
            "highway": "primary",
            "bridge": "yes",
            "tunnel": "yes",
            "surface": "gravel",
        })
        self.assertTrue(flags & ROAD_FLAG_BRIDGE)
        self.assertTrue(flags & ROAD_FLAG_TUNNEL)
        self.assertTrue(flags & ROAD_FLAG_UNPAVED)
        self.assertFalse(flags & ROAD_FLAG_ONEWAY)
        self.assertFalse(flags & ROAD_FLAG_ONEWAY_REVERSE)


if __name__ == "__main__":
    unittest.main()
