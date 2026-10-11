import json
import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from validate_asset_milestone import CATEGORIES, DEFAULT_LEDGER, REGRESSIONS, validate


def finished_library():
    membership = {c: ["engine" if c == "audio" else "controls" if c == "reference_systems" else "model"] for c in CATEGORIES}
    return {
        "outer_inventory_complete": True,
        "archive_members": ["source.apk"], "ignored_archive_members": [],
        "inventory_evidence": "complete hashed outer index",
        "sources": [{
            "id": "source", "members": ["source.apk"], "state": "inventoried",
            "evidence": {"inventory": "all serialized types/container paths", "hashes": "source SHA report"},
            "classification": {c: {"evidence": "classified all source objects", "family_ids": membership[c]} for c in CATEGORIES},
        }],
        "categories": {c: {"reviewed": True, "evidence": "exhaustive family review", "family_ids": membership[c]} for c in CATEGORIES},
        "families": [
            {"id": "model", "source_id": "source", "state": "integrated", "evidence": {
                "import": "Godot imported real batch", "normalize": "bounds/UV/scale report", "render": "Compatibility captures",
                "runtime": "collision/streaming test", "batch": "asset SHA/source commit", "quality_comparison": "existing/candidate render comparison",
            }},
            {"id": "engine", "source_id": "source", "state": "integrated", "evidence": {
                "import": "PCM import", "normalize": "loop/sample validation", "runtime": "AudioStreamPlayer regression",
                "listening": "audited loop and transitions", "batch": "audio SHA/source commit", "quality_comparison": "loop comparison",
            }},
            {"id": "controls", "source_id": "source", "state": "reference", "evidence": {
                "analysis": "control reference notes", "reimplementation_test": "multitouch/drive regression", "batch": "source commit",
            }},
        ],
    }


def finished_ledger():
    return {
        "format_version": 1, "libraries": {"beta1": finished_library(), "beta2": finished_library()},
        "regressions": [{"id": i, "state": "resolved", "evidence": {
            "test": "specific automated regression", "render_or_runtime": "actual engine inspection", "batch": "tested asset/source hash",
        }} for i in sorted(REGRESSIONS)],
        "polish_acceptance": {"complete": True, "game_render": "actual world captures", "controls_driving": "gameplay test",
            "world_coast_roads": "registered geographic inspection", "android_runtime": "device installation/launch evidence"},
    }


class AssetMilestoneTests(unittest.TestCase):
    def test_current_incomplete_ledger_permits_internal_builds_and_blocks_transitions(self):
        report = validate(json.loads(DEFAULT_LEDGER.read_text()))
        self.assertTrue(report["internal_android_builds_allowed"])
        self.assertFalse(report["beta2_allowed"])
        self.assertFalse(report["final_packaging_allowed"])

    def test_fully_evidenced_inventory_and_acceptance_unlock_transitions(self):
        report = validate(finished_ledger())
        self.assertTrue(report["beta2_allowed"])
        self.assertTrue(report["final_packaging_allowed"])

    def test_uninspected_inner_container_blocks_beta2_despite_outer_index(self):
        ledger = finished_ledger()
        ledger["libraries"]["beta1"]["sources"][0]["state"] = "pending"
        self.assertFalse(validate(ledger)["beta2_allowed"])

    def test_deleted_source_cannot_hide_unprocessed_archive_members(self):
        ledger = finished_ledger()
        ledger["libraries"]["beta1"]["archive_members"].append("forgotten.obb")
        with self.assertRaisesRegex(ValueError, "complete outer member index"):
            validate(ledger)

    def test_missing_visual_or_audio_acceptance_blocks_completion(self):
        for family_id, key in (("model", "render"), ("engine", "listening")):
            with self.subTest(family_id=family_id):
                ledger = finished_ledger()
                family = next(f for f in ledger["libraries"]["beta1"]["families"] if f["id"] == family_id)
                family["evidence"].pop(key)
                self.assertFalse(validate(ledger)["beta2_allowed"])

    def test_rejected_family_needs_inspection_and_concrete_reason(self):
        ledger = finished_ledger()
        family = ledger["libraries"]["beta1"]["families"][0]
        family.update(state="rejected", evidence={"inspection": "same four source card triangles"})
        self.assertFalse(validate(ledger)["beta2_allowed"])
        family["evidence"]["reason"] = "Distant cards cannot replace close foliage geometry"
        self.assertTrue(validate(ledger)["beta2_allowed"])

    def test_source_duplicate_requires_content_comparison(self):
        ledger = finished_ledger()
        source = ledger["libraries"]["beta1"]["sources"][0]
        source["state"] = "duplicate"
        self.assertFalse(validate(ledger)["beta2_allowed"])
        source["evidence"]["content_comparison"] = "decoded members have identical SHA256"
        self.assertTrue(validate(ledger)["beta2_allowed"])

    def test_reviewed_absent_category_requires_source_classification_evidence(self):
        ledger = finished_ledger()
        for library in ledger["libraries"].values():
            library["sources"][0]["classification"]["water"] = {"family_ids": [], "evidence": "all-type inventory finds zero water families"}
            library["categories"]["water"] = {"reviewed": True, "family_ids": [], "evidence": "verified source count zero"}
        self.assertTrue(validate(ledger)["beta2_allowed"])
        ledger["libraries"]["beta1"]["sources"][0]["classification"]["water"]["evidence"] = ""
        self.assertFalse(validate(ledger)["beta2_allowed"])

    def test_cannot_start_beta2_with_unresolved_foliage_regression(self):
        ledger = finished_ledger()
        ledger["libraries"]["beta2"]["started"] = True
        next(r for r in ledger["regressions"] if r["id"] == "foliage_atlas_alpha")["state"] = "pending"
        with self.assertRaisesRegex(ValueError, "Beta 2 started before Beta 1"):
            validate(ledger)

    def test_beta2_is_an_independent_quality_pass_and_final_polish_is_required(self):
        ledger = finished_ledger()
        ledger["libraries"]["beta2"]["families"][0]["evidence"].pop("quality_comparison")
        report = validate(ledger)
        self.assertTrue(report["beta2_allowed"])
        self.assertFalse(report["final_packaging_allowed"])
        ledger = finished_ledger()
        ledger["polish_acceptance"]["complete"] = False
        self.assertFalse(validate(ledger)["final_packaging_allowed"])

    def test_cli_reports_pending_work_but_explicit_transition_fails(self):
        script = DEFAULT_LEDGER.parents[2] / "tools/validate_asset_milestone.py"
        for args, expected in (([], 0), (["--require", "beta2"], 1), (["--require", "final_packaging"], 1)):
            result = subprocess.run([sys.executable, str(script), *args], capture_output=True, text=True)
            self.assertEqual(result.returncode, expected, result.stderr)
            self.assertTrue(json.loads(result.stdout)["internal_android_builds_allowed"])


if __name__ == "__main__":
    unittest.main()
