from pathlib import Path
import unittest


PROJECT = Path(__file__).resolve().parents[1] / "project.godot"

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

REQUIRED_AUTOLOADS = {
    "RenderRuntime",
    "BuildingHLOD",
    "ParkedVehicleRuntime",
    "VehicleGarage",
    "VehicleVisualRuntime",
    "VehicleCameraRuntime",
    "StartupMenu",
    "ParishRuntime",
    "ParishMapRuntime",
    "LocationTracker",
}


def autoload_names(text: str) -> set[str]:
    names: set[str] = set()
    in_autoload = False
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("[") and line.endswith("]"):
            in_autoload = line == "[autoload]"
            continue
        if in_autoload and line and not line.startswith(";") and "=" in line:
            names.add(line.split("=", 1)[0].strip())
    return names


class RuntimeScopeTests(unittest.TestCase):
    def test_map_and_cars_scope_excludes_simulation_and_jobs(self):
        names = autoload_names(PROJECT.read_text(encoding="utf-8"))
        self.assertFalse(
            names & FORBIDDEN_AUTOLOADS,
            f"forbidden simulation/job autoloads reintroduced: {sorted(names & FORBIDDEN_AUTOLOADS)}",
        )

    def test_world_and_vehicle_runtime_remains_present(self):
        names = autoload_names(PROJECT.read_text(encoding="utf-8"))
        self.assertFalse(
            REQUIRED_AUTOLOADS - names,
            f"required map/car autoloads missing: {sorted(REQUIRED_AUTOLOADS - names)}",
        )


if __name__ == "__main__":
    unittest.main()
