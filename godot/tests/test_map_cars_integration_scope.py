from pathlib import Path
import unittest

PROJECT = Path(__file__).resolve().parents[1] / "project.godot"

class MapCarsIntegrationScopeTests(unittest.TestCase):
    def test_only_map_quality_bootstrap_autoloads(self):
        text = PROJECT.read_text(encoding="utf-8")
        autoloads = []
        active = False
        for raw in text.splitlines():
            line = raw.strip()
            if line.startswith("[") and line.endswith("]"):
                active = line == "[autoload]"
                continue
            if active and line and not line.startswith(";") and "=" in line:
                autoloads.append(line.split("=", 1)[0].strip())
        self.assertEqual(autoloads, ["MapQualityBootstrap"])

    def test_regressed_simulation_names_absent(self):
        text = PROJECT.read_text(encoding="utf-8")
        for forbidden in (
            "JobRuntime", "JobPersistenceRuntime", "JobGuidanceRuntime",
            "TrafficRuntime", "TrafficSignalRuntime", "TrafficPedestrianSafetyRuntime",
            "PedestrianRuntime", "PedestrianDestinationRuntime", "PedestrianIdleRuntime",
            "VehicleDriverLayer",
        ):
            self.assertNotIn(forbidden + "=", text)

if __name__ == "__main__":
    unittest.main()
