import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "godot" / "tools"))

from hydrology_channel_model import build_channel_candidate


class HydrologyChannelModelTests(unittest.TestCase):
    def test_inferred_seed_never_authorizes_terrain_carving(self):
        candidate = build_channel_candidate(
            waterway="river", width_m=18.0, depth_m=0.81,
            grade_permille=-12.0, width_source="class_fallback",
            depth_source="inferred_seed",
        )
        self.assertEqual(candidate.status, "candidate_only")
        self.assertEqual(candidate.reason, "morphology_evidence_required")

    def test_even_authoritative_context_cannot_promote_inferred_depth(self):
        candidate = build_channel_candidate(
            waterway="drain", width_m=3.0, depth_m=0.24,
            grade_permille=-5.0, width_source="source",
            depth_source="inferred_seed",
            morphology_source="authoritative_engineered_drain",
        )
        self.assertEqual(candidate.status, "candidate_only")
        self.assertEqual(candidate.reason, "depth_is_inferred_seed")

    def test_authoritative_cross_section_can_approve_measured_geometry(self):
        candidate = build_channel_candidate(
            waterway="river", width_m=22.0, depth_m=2.2,
            grade_permille=-8.0, width_source="source",
            depth_source="authoritative_cross_section",
            morphology_source="authoritative_cross_section",
        )
        self.assertEqual(candidate.status, "approved")
        self.assertEqual(candidate.half_width_m, 11.0)
        self.assertGreater(candidate.bank_transition_m, 0.0)

    def test_candidate_geometry_is_safely_bounded(self):
        candidate = build_channel_candidate(
            waterway="stream", width_m=9999.0, depth_m=99.0,
            grade_permille=9999.0, width_source="source",
            depth_source="survey",
        )
        self.assertEqual(candidate.width_m, 200.0)
        self.assertEqual(candidate.depth_m, 12.0)
        self.assertEqual(candidate.grade_permille, 2000.0)
        self.assertLessEqual(candidate.bank_transition_m, 30.0)


if __name__ == "__main__":
    unittest.main()
