import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SELECTOR = ROOT / "scripts" / "vehicle_selector_runtime.gd"
CONTRACT = ROOT / "data" / "owner_fleet_pack_contract.json"


class VehicleSelectorAssetScopeTests(unittest.TestCase):
    def test_selector_hides_unavailable_named_heroes(self):
        text = SELECTOR.read_text(encoding="utf-8")
        self.assertIn('const References = preload("res://scripts/reference_assets.gd")', text)
        self.assertIn('func _dedicated_asset_available(vehicle_id: String) -> bool:', text)
        self.assertIn('ResourceLoader.exists(path)', text)
        self.assertIn('References.manifest_file_matches(hero, manifest)', text)
        self.assertIn('if not _dedicated_asset_available(vehicle_id):', text)
        self.assertIn('CARS · OWNER MEDIA REQUIRED', text)
        self.assertIn('if _vehicle_ids.is_empty():', text)

    def test_owner_selector_contract_is_exact_and_fail_closed(self):
        contract = json.loads(CONTRACT.read_text(encoding="utf-8"))
        ids = contract["available_vehicle_ids"]
        self.assertEqual(contract["available_vehicle_count"], 64)
        self.assertEqual(len(ids), 64)
        self.assertEqual(len(ids), len(set(ids)))
        self.assertIn("toyota_crown", ids)
        self.assertFalse(set(ids) & set(contract["scrapped_vehicle_ids"]))
        self.assertFalse(set(ids) & set(contract["held_missing_vehicle_ids"]))
        self.assertEqual(contract["scrapped_vehicle_ids"], ["port_royal_992", "toyota_mark_x"])
        self.assertEqual(contract["held_missing_vehicle_ids"], ["corvette_c7", "delorean_dmc12"])
        self.assertTrue(contract["policy"]["fail_closed_on_missing_hero"])
        self.assertFalse(contract["policy"]["cross_model_fallback_allowed"])
        self.assertFalse(contract["policy"]["public_ci_fallback_is_owner_candidate"])


if __name__ == "__main__":
    unittest.main()
