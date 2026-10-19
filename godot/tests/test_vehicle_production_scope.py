from pathlib import Path
import json
import unittest

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "scripts" / "vehicle_catalog.gd"
RUNTIME = ROOT / "data" / "vehicle_fleet_runtime.json"
SUPPLEMENTAL = ROOT / "data" / "vehicle_fleet_supplemental.json"

BANNED = {"toyota_mark_x", "port_royal_992"}
HELD = {"corvette_c7", "delorean_dmc12"}
REQUIRED_RECOVERED = {
    "audi_r8",
    "bmw_m3_e46",
    "bmw_m5_e60",
    "chevrolet_camaro",
    "dodge_challenger_rt",
    "honda_s2000",
    "lexus_lfa",
    "mazda_mx5",
    "mazda_rx7",
    "mitsubishi_evo9",
    "nissan_180sx",
    "toyota_supra_rz",
    "carx_commodore",
    "carx_pontiac_solstice",
    "carx_cuda_70",
    "carx_civic_source",
    "carx_driftwagon",
}


def load_ids(path: Path) -> set[str]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    return {str(v.get("id", "")) for v in payload.get("vehicles", []) if v.get("id")}


class VehicleProductionScopeTests(unittest.TestCase):
    def test_banned_and_held_vehicle_policy_is_explicit(self):
        text = CATALOG.read_text(encoding="utf-8")
        self.assertIn('const FORBIDDEN_IDS := ["toyota_mark_x", "port_royal_992"]', text)
        self.assertIn('const HELD_IDS := ["corvette_c7", "delorean_dmc12"]', text)
        self.assertNotIn('const PRODUCTION_IDS := ["toyota_crown", "toyota_mark_x"]', text)

    def test_exact_owner_recovery_fleet_is_64_selectable_cars(self):
        recovered = load_ids(RUNTIME) | load_ids(SUPPLEMENTAL)
        missing = REQUIRED_RECOVERED - recovered
        self.assertFalse(missing, f"missing recovered fleet ids: {sorted(missing)}")
        selectable = (recovered - BANNED - HELD) | {"toyota_crown"}
        self.assertEqual(len(selectable), 64, f"owner fleet drifted: {len(selectable)} selectable ids")
        self.assertTrue(BANNED.isdisjoint(selectable))
        self.assertTrue(HELD.isdisjoint(selectable))

    def test_crown_remains_default_not_only_vehicle(self):
        text = CATALOG.read_text(encoding="utf-8")
        self.assertIn('const DEFAULT_ID := "toyota_crown"', text)
        self.assertIn('for vehicle_id in FleetRegistry.ids():', text)


if __name__ == "__main__":
    unittest.main()
