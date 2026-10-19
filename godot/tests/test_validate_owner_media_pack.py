import hashlib
import json
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))

from validate_owner_media_pack import validate


class OwnerMediaPackValidationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.crown = b"crown-owner-media"
        self.hero = b"fleet-hero-media"

    def tearDown(self):
        self.temp.cleanup()

    def _record(self, path: str, payload: bytes) -> dict:
        return {
            "path": path,
            "bytes": len(payload),
            "sha256": hashlib.sha256(payload).hexdigest(),
        }

    def _write_pack(self, members=None, manifest_records=None):
        if members is None:
            members = {
                "toyota_crown_2013.glb": self.crown,
                "fleet_audi_r8.glb": self.hero,
            }
        if manifest_records is None:
            manifest_records = [self._record(path, payload) for path, payload in members.items()]
        pack = self.root / "FleetReady.zip"
        with zipfile.ZipFile(pack, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("manifest.json", json.dumps({"format_version": 1, "files": manifest_records}))
            for path, payload in members.items():
                archive.writestr(path, payload)
        return pack

    def _write_contract(self, pack: Path, *, minimum=1, pack_sha=True):
        contract = {
            "format_version": 1,
            "pack_sha256": hashlib.sha256(pack.read_bytes()).hexdigest() if pack_sha else "",
            "minimum_fleet_heroes": minimum,
            "required_heroes": [
                {
                    "path": "toyota_crown_2013.glb",
                    "bytes": len(self.crown),
                    "sha256": hashlib.sha256(self.crown).hexdigest(),
                }
            ],
            "forbidden_name_fragments": ["toyota_mark_x", "markx", "992", "porsche"],
        }
        path = self.root / "contract.json"
        path.write_text(json.dumps(contract), encoding="utf-8")
        return path

    def test_accepts_exact_manifest_backed_owner_pack(self):
        pack = self._write_pack()
        proof = validate(pack, self._write_contract(pack))
        self.assertEqual(proof["fleet_heroes"], 1)
        self.assertEqual(proof["manifest_records_verified"], 2)
        self.assertEqual(proof["forbidden_identity_gate"], "pass")
        self.assertEqual(proof["required_heroes"][0]["path"], "toyota_crown_2013.glb")

    def test_rejects_pack_sha_drift(self):
        pack = self._write_pack()
        contract = self._write_contract(pack)
        payload = json.loads(contract.read_text())
        payload["pack_sha256"] = "0" * 64
        contract.write_text(json.dumps(payload))
        with self.assertRaisesRegex(ValueError, "Private pack SHA mismatch"):
            validate(pack, contract)

    def test_rejects_manifest_hash_drift(self):
        members = {
            "toyota_crown_2013.glb": self.crown,
            "fleet_audi_r8.glb": self.hero,
        }
        records = [self._record(path, payload) for path, payload in members.items()]
        records[1]["sha256"] = "f" * 64
        pack = self._write_pack(members, records)
        with self.assertRaisesRegex(ValueError, "Manifest SHA mismatch"):
            validate(pack, self._write_contract(pack))

    def test_rejects_retired_or_forbidden_identity_media(self):
        for forbidden_name in (
            "toyota_mark_x.glb",
            "fleet_port_royal_992.glb",
            "fleet_porsche_911.glb",
        ):
            with self.subTest(forbidden_name=forbidden_name):
                members = {
                    "toyota_crown_2013.glb": self.crown,
                    "fleet_audi_r8.glb": self.hero,
                    forbidden_name: b"forbidden",
                }
                pack = self._write_pack(members)
                with self.assertRaisesRegex(ValueError, "Forbidden private-media identity"):
                    validate(pack, self._write_contract(pack))

    def test_rejects_missing_required_crown(self):
        members = {"fleet_audi_r8.glb": self.hero}
        pack = self._write_pack(members)
        with self.assertRaisesRegex(ValueError, "Required hero is not manifest-backed"):
            validate(pack, self._write_contract(pack))

    def test_rejects_incomplete_private_fleet(self):
        pack = self._write_pack()
        with self.assertRaisesRegex(ValueError, "Private fleet is incomplete"):
            validate(pack, self._write_contract(pack, minimum=2))

    def test_rejects_duplicate_manifest_path(self):
        members = {
            "toyota_crown_2013.glb": self.crown,
            "fleet_audi_r8.glb": self.hero,
        }
        records = [self._record(path, payload) for path, payload in members.items()]
        records.append(dict(records[1]))
        pack = self._write_pack(members, records)
        with self.assertRaisesRegex(ValueError, "Duplicate manifest path"):
            validate(pack, self._write_contract(pack))


if __name__ == "__main__":
    unittest.main()
