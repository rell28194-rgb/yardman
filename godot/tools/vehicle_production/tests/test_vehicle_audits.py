"""Regression fixtures for budget/rig false positives; no recovered vehicle media."""
import argparse
import base64
import contextlib
import copy
import io
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import audit_glb
import generate_lod3_proxy
import validate_lod_chain


class VehicleAuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "proxy.glb"
        with contextlib.redirect_stdout(io.StringIO()):
            generate_lod3_proxy.generate(self.path, 1.8, 1.4, 4.5, 2.6, .32, [.1, .2, .3, 1])
        self.doc = audit_glb.load_glb(self.path)
        self.args = argparse.Namespace(max_triangles=4000, max_materials=4, max_textures=2,
                                       max_texture_dimension=4096, max_texture_memory_mib=64, require_rig=True)

    def metrics(self, doc=None):
        return audit_glb.collect_metrics(self.doc if doc is None else doc, self.path)

    def test_original_proxy_has_four_instanced_wheels_and_valid_rig(self):
        metrics = self.metrics()
        self.assertEqual(152, metrics["triangles"])
        self.assertEqual(56, metrics["unique_mesh_triangles"])
        self.assertTrue(audit_glb.policy_result(metrics, self.args)["pass"])

    def test_unreachable_export_node_is_not_a_scene_draw(self):
        before = self.metrics()
        self.doc["nodes"].append({"mesh": 2})
        after = self.metrics()
        self.assertEqual(before["triangles"], after["triangles"])
        self.assertEqual(before["mesh_instances"], after["mesh_instances"])

    def test_rig_names_on_unused_nodes_do_not_satisfy_contract(self):
        # The nodes still exist, but wheels have been detached from the selected scene.
        self.doc["nodes"][0]["children"] = [1]
        self.assertFalse(self.metrics()["rig_contract"]["pass"])

    def test_rig_requires_parenting_and_unique_node_names(self):
        self.doc["nodes"][4]["children"] = []
        self.doc["nodes"][0]["children"].append(5)
        self.assertFalse(self.metrics()["rig_contract"]["pass"])
        self.doc["nodes"].append({"name": "BodyShell"})
        self.doc["nodes"][0]["children"].append(len(self.doc["nodes"]) - 1)
        self.assertTrue(any("ambiguous" in e for e in self.metrics()["rig_contract"]["errors"]))

    def test_cycle_is_reported_without_recursing_forever(self):
        self.doc["nodes"][1]["children"].append(0)
        metrics = self.metrics()
        self.assertTrue(metrics["scene_errors"])
        self.assertFalse(audit_glb.policy_result(metrics, self.args)["pass"])

    def test_shared_accessors_count_once_but_morph_targets_are_included(self):
        before = self.metrics()["estimated_geometry_bytes"]
        self.doc["meshes"][0]["primitives"].append(copy.deepcopy(self.doc["meshes"][0]["primitives"][0]))
        self.assertEqual(before, self.metrics()["estimated_geometry_bytes"])
        self.doc["accessors"].append({"componentType": 5126, "type": "VEC3", "count": 24})
        self.doc["meshes"][0]["primitives"][0]["targets"] = [{"POSITION": len(self.doc["accessors"]) - 1}]
        self.assertEqual(before + 24 * 12, self.metrics()["estimated_geometry_bytes"])

    def test_invalid_index_reference_does_not_fallback_to_positions(self):
        primitive = self.doc["meshes"][0]["primitives"][0]
        primitive["indices"] = 999
        self.assertEqual(0, audit_glb.triangle_count(self.doc, primitive))
        self.assertFalse(audit_glb.policy_result(self.metrics(), self.args)["pass"])

    def test_invalid_material_and_incomplete_triangles_fail(self):
        primitive = self.doc["meshes"][0]["primitives"][0]
        primitive["material"] = 99
        self.doc["accessors"][primitive["indices"]]["count"] = 35
        errors = self.metrics()["geometry_errors"]
        self.assertTrue(any("invalid material" in e for e in errors))
        self.assertTrue(any("incomplete triangle" in e for e in errors))

    def test_later_corrupt_binary_chunk_is_not_ignored_after_json(self):
        raw = bytearray(self.path.read_bytes())
        json_size = struct.unpack_from("<I", raw, 12)[0]
        struct.pack_into("<I", raw, 20 + json_size, len(raw))
        self.path.write_bytes(raw)
        with self.assertRaisesRegex(ValueError, "past EOF"):
            audit_glb.load_glb(self.path)

    def test_texture_dimensions_and_mips_are_separate_from_encoded_size(self):
        # Header-only data is sufficient for dimensions; this is not image decode validation.
        header = b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR" + struct.pack(">II", 8, 4)
        self.doc["images"] = [{"uri": "data:image/png;base64," + base64.b64encode(header).decode()}]
        metrics = self.metrics()
        self.assertEqual(172, metrics["estimated_texture_rgba8_mip_bytes"])
        self.assertEqual(8, metrics["image_dimensions"][0]["width"])
        self.args.max_texture_dimension = 4
        self.assertFalse(audit_glb.policy_result(metrics, self.args)["pass"])

    def test_unknown_texture_dimensions_fail_closed(self):
        self.doc["images"] = [{"uri": "missing.png"}]
        metrics = self.metrics()
        self.assertIsNone(metrics["estimated_texture_rgba8_mip_bytes"])
        self.assertFalse(audit_glb.policy_result(metrics, self.args)["pass"])

    def test_broken_material_texture_link_is_not_a_zero_texture_pass(self):
        self.doc["materials"][0]["pbrMetallicRoughness"]["baseColorTexture"] = {"index": 99}
        metrics = self.metrics()
        self.assertTrue(metrics["texture_reference_errors"])
        self.assertFalse(audit_glb.policy_result(metrics, self.args)["pass"])

    def test_normal_vertex_count_mismatch_is_rejected(self):
        primitive = self.doc["meshes"][0]["primitives"][0]
        self.doc["accessors"][primitive["attributes"]["NORMAL"]]["count"] = 1
        self.assertTrue(any("NORMAL count" in e for e in self.metrics()["geometry_errors"]))


class LodChainTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.paths = []
        for level, triangles in zip(validate_lod_chain.DEFAULT_LIMITS, (10000, 5000, 1000, 100)):
            path = Path(self.temp.name) / f"{level}.json"
            path.write_text(json.dumps({"policy": {"pass": True}, "metrics": {
                "file": f"{level}.glb", "triangles": triangles, "estimated_geometry_bytes": triangles * 30,
                "materials_referenced": 3, "textures": 0, "rig_contract": {"pass": True},
            }}))
            self.paths.append((level, path))

    def edit(self, index, **changes):
        path = self.paths[index][1]
        doc = json.loads(path.read_text())
        doc["metrics"].update(changes)
        path.write_text(json.dumps(doc))

    def test_full_decreasing_chain_passes_only_static_readiness(self):
        report = validate_lod_chain.validate(self.paths)
        self.assertTrue(report["static_chain_ready"])
        self.assertIn("does not establish runtime", report["readiness_scope"])

    def test_partial_chain_cannot_claim_complete(self):
        self.assertFalse(validate_lod_chain.validate(self.paths[:1])["pass"])
        partial = validate_lod_chain.validate(self.paths[:1], allow_partial=True)
        self.assertTrue(partial["pass"])
        self.assertFalse(partial["static_chain_ready"])

    def test_reduced_triangles_cannot_hide_more_geometry_memory(self):
        self.edit(3, estimated_geometry_bytes=900000)
        self.assertFalse(validate_lod_chain.validate(self.paths)["pass"])

    def test_material_growth_and_unrigged_source_are_rejected(self):
        self.edit(2, materials_referenced=8, rig_contract={"pass": False})
        result = validate_lod_chain.validate(self.paths)
        self.assertTrue(any("materials_referenced" in e for e in result["failures"]))
        self.assertTrue(any("rig contract" in e for e in result["failures"]))

    def test_source_error_is_structured_instead_of_traceback(self):
        self.paths[1][1].write_text("{ invalid")
        result = validate_lod_chain.validate(self.paths)
        self.assertFalse(result["pass"])
        self.assertTrue(any(e.startswith("LOD1:") for e in result["failures"]))

    def test_negative_and_non_numeric_metrics_cannot_pass(self):
        for invalid in (-1, True, "100"):
            self.edit(3, triangles=invalid)
            self.assertFalse(validate_lod_chain.validate(self.paths)["pass"])

    def test_malformed_report_structure_is_a_failure(self):
        for invalid in ([], {"policy": True}, {"policy": {"pass": True}, "metrics": []}):
            self.paths[0][1].write_text(json.dumps(invalid))
            self.assertFalse(validate_lod_chain.validate(self.paths)["pass"])

    def test_texture_memory_growth_is_a_failure_even_with_fewer_textures(self):
        self.edit(0, estimated_texture_rgba8_mip_bytes=4096)
        self.edit(1, estimated_texture_rgba8_mip_bytes=16384)
        result = validate_lod_chain.validate(self.paths)
        self.assertTrue(any("texture memory" in e for e in result["failures"]))


if __name__ == "__main__":
    unittest.main()
