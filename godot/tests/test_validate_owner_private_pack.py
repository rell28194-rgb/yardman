import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]
TOOL_PATH = ROOT / "tools" / "validate_owner_private_pack.py"
SPEC = importlib.util.spec_from_file_location("validate_owner_private_pack", TOOL_PATH)
assert SPEC and SPEC.loader
TOOL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TOOL)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def make_pack(path: Path, *, include_forbidden: bool = False, count: int = 64) -> dict:
    media = {
        "toyota_crown_2013.glb": b"crown",
        "fleet_audi_r8.glb": b"audi",
        "carx_commodore.glb": b"commodore",
    }
    if include_forbidden:
        media["toyota_mark_x.glb"] = b"banned"
    manifest = {
        "format_version": 1,
        "pack_id": "test-owner-pack",
        "private_pack_revision": "test-64",
        "owner_recovery": {
            "available_vehicle_count": count,
            "scrapped_vehicle_ids": ["port_royal_992", "toyota_mark_x"],
            "held_missing_vehicle_ids": ["corvette_c7", "delorean_dmc12"],
        },
        "files": [
            {"path": name, "bytes": len(data), "sha256": digest(data)}
            for name, data in sorted(media.items())
        ],
    }
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("manifest.json", json.dumps(manifest, sort_keys=True))
        for name, data in media.items():
            archive.writestr(name, data)
    return manifest


def contract_for(path: Path) -> dict:
    return {
        "format_version": 1,
        "archive": {
            "filename": path.name,
            "bytes": path.stat().st_size,
            "sha256": TOOL.sha256_file(path),
        },
        "manifest": {
            "pack_id": "test-owner-pack",
            "private_pack_revision": "test-64",
            "available_vehicle_count": 64,
            "scrapped_vehicle_ids": ["port_royal_992", "toyota_mark_x"],
            "held_missing_vehicle_ids": ["corvette_c7", "delorean_dmc12"],
        },
        "required_owner_heroes": [
            "toyota_crown_2013.glb",
            "fleet_audi_r8.glb",
            "carx_commodore.glb",
        ],
        "forbidden_hero_paths": [
            "toyota_mark_x.glb",
            "port_royal_992.glb",
            "porsche_911_992.glb",
        ],
        "graphics_authority": {"required_runtime_files": []},
    }


class OwnerPrivatePackValidationTests(unittest.TestCase):
    def test_exact_pack_contract_is_accepted(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "owner.zip"
            make_pack(path)
            result = TOOL.validate_archive(path, contract_for(path))
            self.assertEqual(result["available_vehicle_count"], 64)
            self.assertEqual(result["pack_id"], "test-owner-pack")

    def test_archive_hash_drift_is_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "owner.zip"
            make_pack(path)
            contract = contract_for(path)
            contract["archive"]["sha256"] = "0" * 64
            with self.assertRaisesRegex(TOOL.OwnerPackError, "SHA-256 mismatch"):
                TOOL.validate_archive(path, contract)

    def test_old_or_partial_vehicle_count_is_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "owner.zip"
            make_pack(path, count=1)
            with self.assertRaisesRegex(TOOL.OwnerPackError, "available_vehicle_count mismatch"):
                TOOL.validate_archive(path, contract_for(path))

    def test_mark_x_media_is_rejected_even_with_valid_hash(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "owner.zip"
            make_pack(path, include_forbidden=True)
            with self.assertRaisesRegex(TOOL.OwnerPackError, "forbidden vehicle media"):
                TOOL.validate_archive(path, contract_for(path))

    def test_missing_recovered_hero_is_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "owner.zip"
            make_pack(path)
            contract = contract_for(path)
            contract["required_owner_heroes"].append("fleet_missing.glb")
            with self.assertRaisesRegex(TOOL.OwnerPackError, "missing required hero media"):
                TOOL.validate_archive(path, contract)

    def test_manifest_controlled_file_tamper_is_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "owner.zip"
            manifest = make_pack(path)
            contract = contract_for(path)
            # Rewrite the archive so its outer hash remains authoritative to the
            # test contract while one manifest-controlled payload is stale.
            with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("manifest.json", json.dumps(manifest, sort_keys=True))
                archive.writestr("toyota_crown_2013.glb", b"tampered")
                archive.writestr("fleet_audi_r8.glb", b"audi")
                archive.writestr("carx_commodore.glb", b"commodore")
            contract["archive"]["bytes"] = path.stat().st_size
            contract["archive"]["sha256"] = TOOL.sha256_file(path)
            with self.assertRaisesRegex(TOOL.OwnerPackError, "byte mismatch|SHA mismatch"):
                TOOL.validate_archive(path, contract)


if __name__ == "__main__":
    unittest.main()
