import copy
import gzip
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from classify_unity_families import (
    LEDGER_CATEGORIES, LEDGER_MAP, OWNER_CATEGORIES, classify_record,
    classify_source, cluster_stem, main, metadata_screen, payload_role,
    public_report, semantic_hints,
)


def record(typ="Mesh", name="wheel_LOD1", path_id=1, source_file="sharedassets1.assets", **extra):
    value = {
        "file": source_file, "path_id": path_id, "type": typ,
        "byte_start": 4096 + path_id * 128, "byte_size": 64,
        "sha256": hashlib.sha256(f"{source_file}:{path_id}:{typ}".encode()).hexdigest(),
        "name": name, "category_candidates": [],
    }
    value.update(extra)
    return value


class ClassificationRulesTests(unittest.TestCase):
    def test_owner_matrix_and_ledger_mapping_keep_every_requested_category(self):
        self.assertEqual(len(OWNER_CATEGORIES), 21)
        self.assertEqual(len(LEDGER_CATEGORIES), 18)
        for category in ("road_markings", "barriers", "signage"):
            self.assertEqual(LEDGER_MAP[category], "road_markings_barriers_signage")
        for category in ("characters", "animations"):
            self.assertEqual(LEDGER_MAP[category], "characters_animations")

    def test_type_and_name_never_imply_acceptance(self):
        cases = [record(name="neutral vehicle"), record("AudioClip", "engine idle"),
                 record("GameObject", "Workshop tool"), record("Shader", "Water")]
        for value in cases:
            with self.subTest(value=value):
                result = classify_record(value, "test")
                self.assertEqual(result["acceptance_state"], "not_accepted")
                self.assertEqual(result["extraction_state"], "not_extracted_by_this_pass")
                self.assertFalse(result["world_layout_substitution_allowed"])
                self.assertEqual(result["dependency_state"], "not_retained_in_saved_inventory")

    def test_polish_mechanical_and_workshop_names_are_scoped_candidates(self):
        expected = {
            "Szlifierka_3": "props", "polerka_anim": "props", "Montazownica_2": "props",
            "Wywazarka_3": "props", "Klucz_udarowy": "props", "Podnosnik": "props",
            "v8_pokrywa_glowicy_stara_2": "vehicle_parts", "wahaczDolny_1": "vehicle_parts",
            "piastaTyl_1": "vehicle_parts", "Felga_zewnetrzna_wlasciwa.023": "vehicle_parts",
        }
        for name, category in expected.items():
            with self.subTest(name=name):
                result = classify_record(record(name=name), "test")
                self.assertEqual(result["primary_category"], category)
                self.assertEqual(result["neutrality"], "unverified_requires_content_inspection")

    def test_generic_words_do_not_match_car_or_glass_by_substring(self):
        for name in ("cardboard_box", "CameraPoint", "scarlet", "discarded"):
            self.assertNotIn("vehicles", {h["category"] for h in semantic_hints(name)})
        self.assertNotIn("vehicle_parts", {h["category"] for h in semantic_hints("grass")})

    def test_audio_idle_does_not_become_character_animation(self):
        result = classify_record(record("AudioClip", "Nissan_Laurel_IDLE_1825rpm"), "test")
        self.assertEqual(result["primary_category"], "audio")
        self.assertEqual(result["category_hints"], ["audio"])
        self.assertEqual(result["semantic_group"], "vehicle_engine_mechanical_audio")

    def test_camelcase_audio_load_states_and_rpm_remain_vehicle_audio(self):
        for name in ("Audi-R8_OnMid_03", "BMW_F82_M4_v06_OnMid 4675RPM", "E36_High", "Sport2_Med_Off"):
            with self.subTest(name=name):
                result = classify_record(record("AudioClip", name), "test")
                self.assertEqual(result["semantic_group"], "vehicle_engine_mechanical_audio")

    def test_soundtrack_hints_require_listening_and_are_not_rejected(self):
        result = classify_record(record("AudioClip", "muzyka 05"), "test")
        self.assertEqual(result["semantic_group"], "possible_soundtrack_requires_listening_disposition")
        self.assertEqual(result["disposition"], "candidate_requires_dependencies_and_validation")

    def test_ui_character_portraits_and_car_icons_are_ui_media(self):
        for name in ("character_carlos", "car_2", "rim_icon_white"):
            result = classify_record(record("Sprite", name), "test")
            self.assertEqual(result["category_hints"], ["hud_ui"])
            self.assertEqual(result["primary_category"], "hud_ui")

    def test_scripts_and_text_assets_cannot_be_direct_media(self):
        for typ in ("MonoBehaviour", "MonoScript", "TextAsset"):
            result = classify_record(record(typ, "AssemblyCars engine wheel"), "test")
            self.assertEqual(result["payload_role"], "script_or_data_reference")
            self.assertEqual(result["primary_category"], "reference_systems")
            self.assertEqual(result["disposition"], "support_or_reference_only")

    def test_named_gameobject_does_not_establish_linked_mesh_family(self):
        result = classify_record(record("GameObject", "Workshop_polisher"), "test")
        self.assertEqual(result["payload_role"], "scene_hierarchy_reference")
        self.assertEqual(result["disposition"], "unlinked_hierarchy_or_component")
        self.assertEqual(result["dependency_state"], "not_retained_in_saved_inventory")

    def test_builtin_status_depends_on_provenance_not_name(self):
        self.assertEqual(payload_role("Mesh", "unity default resources"), "engine_builtin_reference")
        self.assertEqual(payload_role("Mesh", "sharedassets1.assets"), "recoverable_media_candidate")
        candidate = classify_record(record(name="Cube"), "test")
        builtin = classify_record(record(name="Cube", source_file="unity default resources"), "test")
        self.assertNotEqual(candidate["family_id"], builtin["family_id"])
        self.assertEqual(builtin["primary_category"], "reference_systems")

    def test_name_clusters_never_merge_different_files_types_or_numbered_kits(self):
        same = classify_record(record(name="bench_LOD0"), "test")
        lod = classify_record(record(name="bench_LOD1", path_id=2), "test")
        other_file = classify_record(record(name="bench_LOD1", source_file="sharedassets2.assets"), "test")
        other_type = classify_record(record("Texture2D", "bench_LOD1"), "test")
        self.assertEqual(same["family_id"], lod["family_id"])
        self.assertNotEqual(same["family_id"], other_file["family_id"])
        self.assertNotEqual(same["family_id"], other_type["family_id"])
        self.assertNotEqual(cluster_stem("building_1"), cluster_stem("building_2"))
        self.assertNotEqual(cluster_stem("r4_glowica_1"), cluster_stem("r6_glowica_1"))

    def test_unknown_and_unnamed_records_are_explicit_unresolved_buckets(self):
        unknown = classify_record(record("Unknown (999)", ""), "test")
        unnamed = classify_record(record("Mesh", ""), "test")
        support = classify_record(record("Transform", ""), "test")
        self.assertEqual(unknown["disposition"], "unresolved_type_requires_parser_inspection")
        self.assertEqual(unnamed["disposition"], "unresolved_unnamed_media")
        self.assertEqual(support["disposition"], "unlinked_hierarchy_or_component")
        for result in (unknown, unnamed, support):
            self.assertTrue(result["family_id"])
            self.assertEqual(result["family_kind"], "explicit_support_or_unresolved_bucket")

    def test_missing_unity_m_name_null_remains_an_unnamed_support_record(self):
        value = record("Transform", None)
        result = classify_record(value, "test")
        self.assertEqual(result["family_kind"], "explicit_support_or_unresolved_bucket")
        self.assertEqual(result["disposition"], "unlinked_hierarchy_or_component")

    def test_foreign_city_names_hold_context_without_name_only_rejection(self):
        for name in ("LA_Obj_Trash_Container_3_open", "Silverstone1~low", "Combined Mesh (root: scene)"):
            result = classify_record(record(name=name), "test")
            self.assertTrue(result["world_context_flags"])
            self.assertFalse(result["world_layout_substitution_allowed"])
            self.assertNotIn("rejected", result["disposition"])

    def test_mesh_metadata_is_only_scalar_screen_not_triangle_or_bounds_validation(self):
        result = metadata_screen(record(metadata={"vertices": 24, "submeshes": 1, "index_count": 36}))
        self.assertEqual(result["state"], "scalar_metadata_present")
        self.assertEqual(result["acceptance"], "not_geometry_decode_or_runtime_validation")
        self.assertNotIn("triangles", result)
        self.assertNotIn("bounds", result)

    def test_invalid_scalar_metadata_is_preserved_as_blocker(self):
        cases = [
            record(metadata={"vertices": 0, "submeshes": 1, "index_count": 3}),
            record("Texture2D", metadata={"width": 0, "height": 1024, "mip_count": 1}),
            record("AudioClip", metadata={"length_seconds": float("nan"), "frequency": 22050, "channels": 1}),
            record("AnimationClip", metadata={"sample_rate": -1}),
        ]
        for value in cases:
            result = metadata_screen(value)
            self.assertEqual(result["state"], "flagged")
            self.assertTrue(result["flags"])


class CompleteInventoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.inventory = self.base / "inventory"
        self.inventory.mkdir()
        self.objects = [
            record("Mesh", "private_candidate_wheel", 1, metadata={"vertices": 36, "submeshes": 1, "index_count": 72}),
            record("Texture2D", "private_candidate_wheel_d", 2, metadata={"width": 512, "height": 512, "mip_count": 10}),
            record("MonoBehaviour", "AssemblyCars", 3),
            record("Transform", "", 4),
            record("Unknown (999)", "", 5),
            record("AudioClip", "engine idle", 6, metadata={"length_seconds": 2, "frequency": 22050, "channels": 1}),
            record("GameObject", "private_candidate_wheel", 7),
        ]
        self.summary = {
            "source_family": "test", "object_count": len(self.objects),
            "serialized_type_counts": {r["type"]: sum(o["type"] == r["type"] for o in self.objects) for r in self.objects},
            "sources": [{"path": "source.apk", "bytes": 9999}],
            "coverage": {"serialized_type_inventory_complete": True, "object_identity_hashes_complete": True},
            "parse_errors": [], "metadata_errors": [], "hash_errors": [],
        }
        self.write_inputs()

    def write_inputs(self):
        self.objects_path = self.inventory / "test-objects.ndjson.gz"
        with gzip.open(self.objects_path, "wt") as stream:
            for value in self.objects:
                stream.write(json.dumps(value) + "\n")
        self.summary_path = self.inventory / "test-unity-summary.json"
        self.summary_path.write_text(json.dumps(self.summary))

    def classify(self, output="output"):
        return classify_source(self.objects_path, self.summary_path, self.base / output)

    def test_every_record_occurs_once_in_object_manifest_and_once_in_family_manifest(self):
        report = self.classify()
        with gzip.open(self.base / "output/test/classified-objects.ndjson.gz", "rt") as stream:
            objects = [json.loads(line) for line in stream]
        with gzip.open(self.base / "output/test/families.ndjson.gz", "rt") as stream:
            families = [json.loads(line) for line in stream]
        identities = [r["classification"]["identity"] for r in objects]
        membership = [obj["identity"] for family in families for obj in family["objects"]]
        self.assertEqual(len(objects), len(self.objects))
        self.assertEqual(len(set(identities)), len(self.objects))
        self.assertCountEqual(identities, membership)
        self.assertEqual(report["classification_coverage"]["unassigned_records"], 0)
        self.assertFalse(report["classification_coverage"]["linked_family_classification_complete"])
        self.assertEqual(sum(report["payload_role_counts"].values()), len(objects))
        self.assertEqual(sum(report["disposition_counts"].values()), len(objects))

    def test_all_categories_have_honest_open_dispositions_without_absence_claims(self):
        report = self.classify()
        self.assertEqual(set(report["owner_category_matrix"]), set(OWNER_CATEGORIES))
        for row in report["owner_category_matrix"].values():
            self.assertEqual(row["inventory_records_evaluated"], len(self.objects))
            self.assertFalse(row["absence_confirmed"])
            self.assertEqual(row["extracted_families"], 0)
            self.assertEqual(row["explicit_content_rejections"], 0)
        self.assertEqual(report["owner_category_matrix"]["water"]["disposition"], "unresolved_no_identifying_hint")

    def test_public_report_contains_aggregates_no_object_names_ids_or_bytes(self):
        report = public_report([self.classify()])
        serialized = json.dumps(report)
        self.assertNotIn("private_candidate", serialized)
        self.assertNotIn("AssemblyCars", serialized)
        self.assertNotIn("test:sharedassets1.assets:", serialized)
        self.assertNotIn(self.objects[0]["sha256"], serialized)
        self.assertNotIn('"objects": [', serialized)

    def test_same_serialized_hash_is_not_content_duplicate_rejection(self):
        self.objects[1] = record("Mesh", "different_source_dependencies", 2,
                                 sha256=self.objects[0]["sha256"])
        self.summary["serialized_type_counts"] = {r["type"]: sum(o["type"] == r["type"] for o in self.objects) for r in self.objects}
        self.write_inputs()
        report = self.classify()
        self.assertEqual(report["same_serialized_record_hash_groups"], 1)
        self.assertEqual(report["duplicate_rejections"], 0)
        groups = json.loads((self.base / "output/test/same-record-hash-groups.json").read_text())
        self.assertIn("stream_comparison", groups[0]["disposition"])
        self.assertEqual(len(groups[0]["identities"]), 2)

    def test_duplicate_identity_fails_instead_of_double_counting(self):
        self.objects.append(copy.deepcopy(self.objects[0]))
        self.write_inputs()
        with self.assertRaisesRegex(ValueError, "duplicate object identity"):
            self.classify()
        self.assertFalse((self.base / "output/test/classification-summary.json").exists())

    def test_missing_records_or_type_drift_fail_reconciliation(self):
        self.summary["object_count"] += 1
        self.write_inputs()
        with self.assertRaisesRegex(ValueError, "count mismatch"):
            self.classify()
        self.summary["object_count"] -= 1
        self.summary["serialized_type_counts"]["Mesh"] = 999
        self.write_inputs()
        with self.assertRaisesRegex(ValueError, "type counts mismatch"):
            self.classify()

    def test_input_hash_and_parser_errors_fail_closed(self):
        for key in ("sha256", "byte_start", "byte_size"):
            with self.subTest(key=key):
                original = self.objects[0][key]
                self.objects[0][key] = "invalid" if key == "sha256" else -1
                self.write_inputs()
                with self.assertRaises(ValueError):
                    self.classify()
                self.objects[0][key] = original
        self.summary["parse_errors"] = ["unparsed stream"]
        self.write_inputs()
        with self.assertRaisesRegex(ValueError, "parse_errors"):
            self.classify()

    def test_private_output_is_refused_inside_public_tree(self):
        tool = Path(__file__).resolve().parents[1] / "tools/classify_unity_families.py"
        result = subprocess.run([sys.executable, str(tool), "--inventory-dir", str(self.inventory),
                                 "--output-dir", str(tool.parents[1] / "forbidden-private"), "--source", "test"],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("private manifests must be outside", result.stderr)
        self.assertFalse((tool.parents[1] / "forbidden-private").exists())

    def test_classified_checkpoint_hashes_are_repeatable(self):
        first = self.classify("output")
        second = self.classify("second-output")
        self.assertEqual(first, second)

    def test_cli_writes_public_report_only_after_source_reconciliation(self):
        public = self.base / "report.json"
        result = main(["--inventory-dir", str(self.inventory), "--output-dir", str(self.base / "cli-out"),
                       "--source", "test", "--public-report", str(public)])
        self.assertEqual(result, 0)
        self.assertTrue(public.exists())
        self.assertEqual(json.loads(public.read_text())["sources"][0]["accepted_families"], 0)


if __name__ == "__main__":
    unittest.main()
