import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "project.godot"
CATALOG = ROOT / "scripts" / "vehicle_catalog.gd"
RUNTIME = ROOT / "data" / "vehicle_fleet_runtime.json"
SUPPLEMENTAL = ROOT / "data" / "vehicle_fleet_supplemental.json"

FORBIDDEN_AUTOLOADS = {
    "JobRuntime", "JobPersistenceRuntime", "JobGuidanceRuntime",
    "TrafficRuntime", "TrafficSignalRuntime", "TrafficVisualVarietyRuntime",
    "TrafficBrakeLightRuntime", "TrafficHeadlightRuntime",
    "PedestrianRuntime", "PedestrianDestinationRuntime", "PedestrianIdleRuntime",
    "TrafficPedestrianSafetyRuntime", "VehicleDriverLayer",
}
SCRAPPED_IDS = {"toyota_mark_x", "port_royal_992"}
REQUIRED_VEHICLE_FILES = {
    "vehicle_controller.gd", "vehicle_model.gd", "vehicle_catalog.gd",
    "vehicle_fleet_registry.gd", "vehicle_powertrain.gd", "vehicle_runtime_contract.gd",
}


def autoload_names(text: str) -> set[str]:
    names = set()
    active = False
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("[") and line.endswith("]"):
            active = line == "[autoload]"
            continue
        if active and line and not line.startswith(";") and "=" in line:
            names.add(line.split("=", 1)[0].strip())
    return names


class CleanVehicleIntegrationTests(unittest.TestCase):
    def test_reset_runtime_boundary_is_still_clean(self):
        names = autoload_names(PROJECT.read_text(encoding="utf-8"))
        self.assertEqual(names, {"MapQualityBootstrap"})
        self.assertFalse(names & FORBIDDEN_AUTOLOADS)

    def test_production_vehicle_stack_is_present(self):
        scripts = ROOT / "scripts"
        missing = sorted(name for name in REQUIRED_VEHICLE_FILES if not (scripts / name).is_file())
        self.assertEqual(missing, [])

    def test_crown_is_default_and_scrapped_selectors_are_blocked(self):
        source = CATALOG.read_text(encoding="utf-8")
        self.assertRegex(source, r'const\s+DEFAULT_ID\s*:=\s*"toyota_crown"')
        for vehicle_id in SCRAPPED_IDS:
            self.assertIn(vehicle_id, source)
        self.assertIn("SCRAPPED_IDS", source)
        self.assertNotIn('PRODUCTION_IDS := ["toyota_crown", "toyota_mark_x", "port_royal_992"]', source)

    def test_recovered_fleet_is_real_and_not_just_crown(self):
        records = []
        for path in (RUNTIME, SUPPLEMENTAL):
            payload = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(payload.get("format_version"), 1)
            records.extend(payload.get("vehicles", []))
        ids = {str(record.get("id", "")) for record in records}
        self.assertGreaterEqual(len(ids), 17)
        self.assertTrue({"audi_r8", "bmw_m3_e46", "mazda_rx7", "nissan_skyline_r34", "toyota_supra_rz"} <= ids)
        self.assertFalse(ids & SCRAPPED_IDS)


if __name__ == "__main__":
    unittest.main()
