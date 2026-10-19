import hashlib
import json
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))

from stage_owner_media_pack import MARKER, stage


class OwnerMediaStageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.crown = b"crown"
        self.hero = b"audi-r8"

    def tearDown(self):
        self.temp.cleanup()

    def _record(self, path, payload):
        return {"path": path, "bytes": len(payload), "sha256": hashlib.sha256(payload).hexdigest()}

    def _pack(self, members=None):
        members = members or {
            "toyota_crown_2013.glb": self.crown,
            "fleet_audi_r8.glb": self.hero,
        }
        records = [self._record(path, payload) for path, payload in members.items()]
        pack = self.root / "pack.zip"
        with zipfile.ZipFile(pack, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("manifest.json", json.dumps({"format_version": 1, "files": records}))
            for path, payload in members.items():
                archive.writestr(path, payload)
        return pack, records

    def _contract(self, pack, required=True, owner_minimum=2):
        required_heroes = []
        if required:
            required_heroes.append(self._record("toyota_crown_2013.glb", self.crown))
        contract = {
            "format_version": 1,
            "pack_sha256": hashlib.sha256(pack.read_bytes()).hexdigest(),
            "minimum_fleet_heroes": 1 if required else 0,
            "minimum_owner_vehicle_heroes": owner_minimum,
            "required_heroes": required_heroes,
            "forbidden_name_fragments": ["toyota_mark_x", "992", "porsche"],
        }
        path = self.root / "contract.json"
        path.write_text(json.dumps(contract), encoding="utf-8")
        return path

    def test_stages_only_manifest_media_and_preserves_tracked_control(self):
        pack, _ = self._pack()
        destination = self.root / "user_reference"
        destination.mkdir()
        control = destination / "toyota_crown_2013_identity.tres"
        control.write_text("tracked-control", encoding="utf-8")
        receipt = stage(pack, self._contract(pack), destination)
        self.assertEqual((destination / "toyota_crown_2013.glb").read_bytes(), self.crown)
        self.assertEqual((destination / "fleet_audi_r8.glb").read_bytes(), self.hero)
        self.assertEqual(control.read_text(encoding="utf-8"), "tracked-control")
        self.assertTrue((destination / "manifest.json").is_file())
        self.assertTrue((destination / MARKER).is_file())
        self.assertEqual(receipt["owner_vehicle_heroes"], 2)

    def test_refuses_to_mix_unrecognized_existing_private_files(self):
        pack, _ = self._pack()
        destination = self.root / "user_reference"
        destination.mkdir()
        (destination / "stale_car.glb").write_bytes(b"old")
        with self.assertRaisesRegex(ValueError, "unrecognized existing files"):
            stage(pack, self._contract(pack), destination)

    def test_restage_replaces_prior_manifest_media(self):
        pack, _ = self._pack()
        destination = self.root / "user_reference"
        first = stage(pack, self._contract(pack), destination)
        self.assertEqual(first["owner_vehicle_heroes"], 2)
        (destination / "fleet_audi_r8.glb").write_bytes(b"corrupted-after-stage")
        second = stage(pack, self._contract(pack), destination)
        self.assertEqual(second["owner_vehicle_heroes"], 2)
        self.assertEqual((destination / "fleet_audi_r8.glb").read_bytes(), self.hero)

    def test_rejects_path_traversal_before_writing(self):
        members = {"../fleet_escape.glb": b"escape"}
        pack, _ = self._pack(members)
        destination = self.root / "user_reference"
        contract = self._contract(pack, required=False, owner_minimum=0)
        with self.assertRaisesRegex(ValueError, "Unsafe owner-media path"):
            stage(pack, contract, destination)
        self.assertFalse((self.root / "fleet_escape.glb").exists())


if __name__ == "__main__":
    unittest.main()
