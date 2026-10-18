import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "godot" / "tools"))

from hydrology_channel_model import build_channel_candidate
from hydrology_terrain_plan import plan_terrain_operation
from hydrology_terrain_delta import build_terrain_delta_profile, sample_cross_section_delta


def operation(approved=True):
    channel = build_channel_candidate(
        waterway="river", width_m=12.0, depth_m=1.4, grade_permille=-8.0,
        width_source="source",
        depth_source="authoritative_cross_section" if approved else "inferred_seed",
        morphology_source="authoritative_cross_section",
    )
    return plan_terrain_operation(channel)


class HydrologyTerrainDeltaTests(unittest.TestCase):
    def test_blocked_operation_emits_zero_delta(self):
        profile = build_terrain_delta_profile(operation(False), morphology_family="steep_wet_mountain")
        self.assertEqual(profile.status, "blocked")
        self.assertEqual(sample_cross_section_delta(profile, 0), 0.0)

    def test_unknown_family_cannot_invent_earthwork(self):
        profile = build_terrain_delta_profile(operation(), morphology_family="generic_jamaica")
        self.assertEqual((profile.status, profile.max_excavation_m), ("blocked", 0.0))

    def test_steep_and_lowland_profiles_are_materially_distinct(self):
        steep = build_terrain_delta_profile(operation(), morphology_family="steep_wet_mountain")
        low = build_terrain_delta_profile(operation(), morphology_family="lowland_wetland")
        self.assertEqual((steep.status, low.status), ("approved", "approved"))
        self.assertLess(steep.bed_half_width_m, low.bed_half_width_m)
        self.assertLess(steep.bank_transition_m, low.bank_transition_m)
        self.assertLess(steep.shoulder_slope_ratio, low.shoulder_slope_ratio)

    def test_excavation_never_exceeds_approved_depth(self):
        profile = build_terrain_delta_profile(operation(), morphology_family="lowland_wetland")
        samples = [sample_cross_section_delta(profile, x) for x in (-50, -10, -2, 0, 2, 10, 50)]
        self.assertGreaterEqual(min(samples), -1.4)
        self.assertLessEqual(max(samples), 0.0)

    def test_cross_section_returns_to_zero_outside_transition(self):
        profile = build_terrain_delta_profile(operation(), morphology_family="steep_wet_mountain")
        edge = profile.bed_half_width_m + profile.bank_transition_m
        self.assertEqual(sample_cross_section_delta(profile, edge + 0.01), 0.0)
        self.assertEqual(sample_cross_section_delta(profile, -(edge + 0.01)), 0.0)


if __name__ == "__main__":
    unittest.main()
