"""Identity, recursion and acceptance boundaries for private Gangstar auditing."""
import gzip
import io
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from inspect_gangstar_resources import OWNER_CATEGORIES, audit, classify, decode_range, format_of, inspect_zip


def archive(members):
    target = io.BytesIO()
    with zipfile.ZipFile(target, "w", compression=zipfile.ZIP_DEFLATED) as z:
        for name, payload in members:
            z.writestr(name, payload)
    return target.getvalue()


class GangstarResourceTests(unittest.TestCase):
    def test_nested_archive_covers_duplicate_names_and_never_extracts_paths(self):
        inner = archive([("../tree.bdae", b"BRES" + b"\0" * 64)])
        rows = inspect_zip(archive([("scene.zip", inner), ("road_sign.tga", b"texture")]), "fixture")
        self.assertEqual(len(rows), 3)
        leaf = next(r for r in rows if r["name"] == "../tree.bdae")
        self.assertFalse(leaf["path_safe_for_extraction"])
        self.assertEqual(leaf["state"], "crc_sha_verified")
        self.assertEqual(len(leaf["sha256"]), 64)
        self.assertFalse(leaf["accepted"])

    def test_crc_failure_remains_a_blocker(self):
        payload = bytearray(archive([("object", b"original payload")]))
        # Corrupt compressed bytes, keeping a valid directory/header.
        pos = 30 + len("object")
        payload[pos + 2] ^= 0xff
        rows = inspect_zip(bytes(payload), "fixture")
        self.assertEqual(rows[0]["state"], "blocked")

    def test_no_name_only_acceptance_or_category_absence(self):
        r = classify("city.bdae", "ZIP")
        self.assertFalse(r["accepted"])
        self.assertFalse(r["category_absence_proven"])
        self.assertEqual(r["role"], "container_requires_member_dispositions")
        self.assertIn("buildings", r["candidate_categories"])
        self.assertEqual(len(OWNER_CATEGORIES), 21)

    def test_nested_shader_and_collada_formats_keep_reference_role(self):
        self.assertEqual(format_of(b"#version 100 es\nvoid main()", "Water_FS.glsl"), "GLSL_source")
        self.assertEqual(format_of(b"<?xml version='1.0'?><COLLADA xmlns='url'>", "source.dae"), "COLLADA_XML")
        self.assertEqual(classify("Water_FS.glsl", "GLSL_source")["role"], "reference_system_not_direct_godot_resource")
        self.assertEqual(format_of(b"\xff\xff", "shader.glsl"), "unresolved")

    def test_olya_ranges_and_exact_sizes(self):
        body = b"BRESexample"
        raw = struct.pack("<4s5I2I", b"OLYA", 1, len(body), len(body), 0, 0, 32, len(body)) + body
        self.assertEqual(decode_range(raw, 0x200, len(body)), body)
        with self.assertRaises(ValueError):
            decode_range(raw[:-1], 0x200, len(body))

    def test_no_source_bytes_without_apk_cannot_close_nested_inventory(self):
        with tempfile.TemporaryDirectory() as tmp:
            index = Path(tmp) / "index.gz"
            row = {"container": "test", "name": "interior.bdae", "index": 0,
                   "sha256": "a" * 64, "decode_status": "exact_length_pass",
                   "decoded": {"sha256": "b" * 64, "bytes": 100, "format": "ZIP"}}
            with gzip.open(index, "wt") as f:
                f.write(json.dumps(row) + "\n")
            report = audit(index, Path(tmp) / "private.json")
            self.assertEqual(report["nested_zip_verified"], 0)
            self.assertEqual(report["nested_zip_blocked"], 1)
            self.assertEqual(set(report["categories"]), set(OWNER_CATEGORIES))
            self.assertFalse(report["beta2_allowed"])


if __name__ == "__main__":
    unittest.main()
