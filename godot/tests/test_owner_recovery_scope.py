import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "project.godot"
SELECTOR = ROOT / "scripts" / "vehicle_selector_runtime.gd"
FLEET_FILES = [
    ROOT / "data" / "vehicle_fleet_runtime.json",
    ROOT / "data" / "vehicle_fleet_supplemental.json",
]
SCRAPPED = {"toyota_mark_x", "port_royal_992"}
FORBIDDEN_AUTOLOADS = {
    "TrafficRuntime",
    "TrafficSignalRuntime",
    "PedestrianRuntime",
    "PedestrianDestinationRuntime",
    "PedestrianIdleRuntime",
    "TrafficPedestrianSafetyRuntime",
    "TrafficVisualVarietyRuntime",
    "TrafficBrakeLightRuntime",
    "TrafficHeadlightRuntime",
    "JobRuntime",
    "JobPersistenceRuntime",
    "JobGuidanceRuntime",
    "VehicleDriverLayer",
}


def autoloads(text: str) -> dict[str, str]:
    result: dict[str, str] = {}
    active = False
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("[") and line.endswith("]"):
            active = line == "[autoload]"
            continue
        if active and line and not line.startswith(";") and "=" in line:
            name, value = line.split("=", 1)
            result[name.strip()] = value.strip().strip('"')
    return result


class OwnerRecoveryScopeTests(unittest.TestCase):
    def test_runtime_boundary_is_map_cars_only(self):
        project = PROJECT.read_text(encoding="utf-8")
        loaded = autoloads(project)
        self.assertFalse(FORBIDDEN_AUTOLOADS & set(loaded), sorted(FORBIDDEN_AUTOLOADS & set(loaded)))
        self.assertEqual(loaded.get("MapQualityBootstrap"), "*res://scripts/map_quality_bootstrap.gd")
        self.assertEqual(loaded.get("VehicleGarage"), "*res://scripts/vehicle_selector_runtime.gd")

    def test_owner_renderer_matches_reset_path(self):
        project = PROJECT.read_text(encoding="utf-8")
        self.assertIn('renderer/rendering_method="gl_compatibility"', project)
        self.assertIn('renderer/rendering_method.mobile="gl_compatibility"', project)

    def test_scrapped_vehicles_are_hard_filtered(self):
        selector = SELECTOR.read_text(encoding="utf-8")
        for vehicle_id in SCRAPPED:
            self.assertIn(vehicle_id, selector)
        self.assertIn("SCRAPPED_IDS.has(value)", selector)
        self.assertIn("SCRAPPED_IDS.has(vehicle_id)", selector)

    def test_recovered_fleet_is_runtime_data_not_docs_only(self):
        ids: set[str] = set()
        hero_scenes: set[str] = set()
        for path in FLEET_FILES:
            payload = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(payload.get("format_version"), 1)
            for vehicle in payload.get("vehicles", []):
                vehicle_id = str(vehicle.get("id", ""))
                if not vehicle_id:
                    continue
                self.assertNotIn(vehicle_id, SCRAPPED)
                ids.add(vehicle_id)
                hero_scene = str(vehicle.get("hero_scene", ""))
                self.assertTrue(hero_scene, vehicle_id)
                hero_scenes.add(hero_scene)
        self.assertGreaterEqual(len(ids), 17)
        self.assertEqual(len(ids), len(hero_scenes))

    def test_reset_parish_navigation_is_in_scene(self):
        scene = (ROOT / "main.tscn").read_text(encoding="utf-8")
        self.assertIn('res://scripts/parish_navigation.gd', scene)
        self.assertIn('[node name="ParishNavigation"', scene)


if __name__ == "__main__":
    unittest.main()
