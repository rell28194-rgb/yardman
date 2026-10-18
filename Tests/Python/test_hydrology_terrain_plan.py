import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "godot" / "tools"))

from hydrology_channel_model import build_channel_candidate
from hydrology_crossings import classify_crossing
from hydrology_terrain_plan import plan_terrain_operation


def channel(*, approved=True):
    return build_channel_candidate(
        waterway="river", width_m=12.0, depth_m=1.4,
        grade_permille=-8.0, width_source="source",
        depth_source="authoritative_cross_section" if approved else "inferred_seed",
        morphology_source="authoritative_cross_section",
    )


class HydrologyTerrainPlanTests(unittest.TestCase):
    def test_inferred_channel_never_mutates_dem(self):
        op = plan_terrain_operation(channel(approved=False))
        self.assertEqual((op.status, op.action), ("blocked", "none"))

    def test_approved_channel_can_incise_away_from_roads(self):
        op = plan_terrain_operation(channel())
        self.assertEqual(op.status, "approved")
        self.assertEqual(op.action, "incise_registered_channel")

    def test_unknown_crossing_blocks_even_approved_channel(self):
        crossing = classify_crossing()
        op = plan_terrain_operation(channel(), crossing)
        self.assertEqual((op.status, op.action), ("blocked", "none"))
        self.assertEqual(op.reason, "crossing_not_approved")

    def test_bridge_and_culvert_allow_channel_below_road(self):
        for crossing in (classify_crossing(road_bridge=True),
                         classify_crossing(explicit_culvert=True)):
            op = plan_terrain_operation(channel(), crossing)
            self.assertEqual(op.status, "approved")
            self.assertEqual(op.action, "incise_channel_below_road")

    def test_explicit_ford_allows_at_grade_channel(self):
        op = plan_terrain_operation(channel(), classify_crossing(explicit_ford=True))
        self.assertEqual(op.status, "approved")
        self.assertEqual(op.action, "incise_at_grade_ford_channel")

    def test_road_tunnel_requires_clearance_before_channel_mutation(self):
        op = plan_terrain_operation(channel(), classify_crossing(road_tunnel=True))
        self.assertEqual((op.status, op.action), ("blocked", "none"))
        self.assertEqual(op.reason, "tunnel_clearance_evidence_required")

    def test_conflicting_crossing_evidence_is_non_destructive(self):
        crossing = classify_crossing(road_bridge=True, explicit_ford=True)
        op = plan_terrain_operation(channel(), crossing)
        self.assertEqual((op.status, op.action), ("blocked", "none"))


if __name__ == "__main__":
    unittest.main()
