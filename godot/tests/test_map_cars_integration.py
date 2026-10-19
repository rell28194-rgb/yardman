from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "project.godot"
CATALOG = ROOT / "scripts" / "vehicle_catalog.gd"
SELECTOR = ROOT / "scripts" / "vehicle_selector_runtime.gd"

FORBIDDEN_AUTOLOADS = {
    "JobRuntime",
    "JobPersistenceRuntime",
    "JobGuidanceRuntime",
    "TrafficRuntime",
    "TrafficSignalRuntime",
    "PedestrianRuntime",
    "PedestrianDestinationRuntime",
    "PedestrianIdleRuntime",
    "TrafficPedestrianSafetyRuntime",
    "TrafficVisualVarietyRuntime",
    "TrafficBrakeLightRuntime",
    "TrafficHeadlightRuntime",
    "VehicleDriverLayer",
    "VehicleGarage",
}
EXPECTED_AUTOLOADS = {"MapQualityBootstrap", "VehicleSelector"}


def autoloads(text: str) -> set[str]:
    result: set[str] = set()
    active = False
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("[") and line.endswith("]"):
            active = line == "[autoload]"
            continue
        if active and line and not line.startswith(";") and "=" in line:
            result.add(line.split("=", 1)[0].strip())
    return result


class MapCarsIntegrationTests(unittest.TestCase):
    def test_runtime_shell_is_map_and_cars_only(self):
        names = autoloads(PROJECT.read_text(encoding="utf-8"))
        self.assertEqual(EXPECTED_AUTOLOADS, names)
        self.assertFalse(names & FORBIDDEN_AUTOLOADS)

    def test_crown_is_default_and_scrapped_cars_are_blacklisted(self):
        text = CATALOG.read_text(encoding="utf-8")
        self.assertRegex(text, r'const DEFAULT_ID\s*:=\s*"toyota_crown"')
        self.assertRegex(text, r'const PRODUCTION_IDS\s*:=\s*\["toyota_crown"\]')
        match = re.search(r'const SCRAPPED_IDS\s*:=\s*\[([^\]]+)\]', text)
        self.assertIsNotNone(match)
        scrapped = match.group(1)
        self.assertIn('"toyota_mark_x"', scrapped)
        self.assertIn('"port_royal_992"', scrapped)

    def test_selector_has_no_job_or_simulation_dependencies(self):
        text = SELECTOR.read_text(encoding="utf-8")
        forbidden_dependencies = [
            'res://scripts/job_',
            '/root/JobRuntime',
            '/root/JobPersistenceRuntime',
            'res://scripts/traffic_',
            'res://scripts/pedestrian_',
        ]
        for dependency in forbidden_dependencies:
            self.assertNotIn(dependency, text)

    def test_selector_blocks_procedural_or_missing_named_heroes(self):
        text = SELECTOR.read_text(encoding="utf-8")
        self.assertIn('yardman_hero_asset_missing_or_invalid', text)
        self.assertIn('yardman_procedural_vehicle_fallback', text)
        self.assertIn('actual_scene != expected_scene', text)
        self.assertIn('visual.visible = false', text)


if __name__ == "__main__":
    unittest.main()
