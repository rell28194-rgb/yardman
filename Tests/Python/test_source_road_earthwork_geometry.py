import math
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "godot" / "tools"))

from build_source_road_earthwork_geometry import source_geometry_supported


class SourceRoadEarthworkGeometryTests(unittest.TestCase):
    def test_source_cutting_requires_raised_shoulder_support(self):
        supported, reason = source_geometry_supported("source_cutting", 1.2, -0.3)
        self.assertTrue(supported)
        self.assertIn("raised", reason)

    def test_source_cutting_without_resolvable_relief_is_deferred(self):
        supported, reason = source_geometry_supported("source_cutting", 0.2, -0.1)
        self.assertFalse(supported)
        self.assertIn("lacks", reason)

    def test_source_embankment_requires_lowered_shoulder_support(self):
        supported, reason = source_geometry_supported("source_embankment", 0.4, -1.1)
        self.assertTrue(supported)
        self.assertIn("lowered", reason)

    def test_source_embankment_without_resolvable_relief_is_deferred(self):
        supported, reason = source_geometry_supported("source_embankment", 0.1, -0.2)
        self.assertFalse(supported)
        self.assertIn("lacks", reason)

    def test_dem_candidate_can_never_enter_source_geometry(self):
        supported, _ = source_geometry_supported("dem_sidehill_candidate", 12.0, -12.0)
        self.assertFalse(supported)

    def test_nonfinite_profile_is_rejected(self):
        supported, reason = source_geometry_supported("source_cutting", math.nan, 2.0)
        self.assertFalse(supported)
        self.assertIn("non-finite", reason)

    def test_invalid_threshold_is_rejected(self):
        with self.assertRaises(ValueError):
            source_geometry_supported("source_cutting", 1.0, 1.0, 0.0)


if __name__ == "__main__":
    unittest.main()
