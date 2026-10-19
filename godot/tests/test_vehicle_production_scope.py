from pathlib import Path
import json
import unittest

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "scripts" / "vehicle_catalog.gd"
RUNTIME = ROOT / "data" / "vehicle_fleet_runtime.json"
SUPPLEMENTAL = ROOT / "data" / "vehicle_fleet_supplemental.json"

BANNED = {"toyota_mark_x", "port_royal_992"}
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
}


def load_ids(path: Path) -> set[str]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    return {str(v.get("id", "")) for v in payload.get("vehicles", []) if v.get("id")}


class VehicleProductionScopeTests(unittest.TestCase):
    def test_banned_vehicles_are_hard_forbidden(self):
        text = CATALOG.read_text(encoding="utf-8")
        self.assertIn('const FORBIDDEN_IDS := ["toyota_mark_x", "port_royal_992"]', text)
        self.assertNotIn('const PRODUCTION_IDS := ["toyota_crown", "toyota_mark_x"]', text)

    def test_recovered_fleet_cannot_collapse_to_single_car(self):
        recovered = load_ids(RUNTIME) | load_ids(SUPPLEMENTAL)
        self.assertGreaterEqual(len(recovered), 20)
        self.assertFalse(REQUIRED_RECOVERED - recovered, f"missing recovered fleet ids: {sorted(REQUIRED_RECOVERED - recovered)}")
        self.assertTrue(BANNED.isdisjoint(recovered) or BANNED <= {"toyota_mark_x", "port_royal_992"})

    def test_crown_remains_default_not_only_vehicle(self):
        text = CATALOG.read_text(encoding="utf-8")
        self.assertIn('const DEFAULT_ID := "toyota_crown"', text)
        self.assertIn('for vehicle_id in FleetRegistry.ids():', text)


if __name__ == "__main__":
    unittest.main()
