import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class MapCarsRecoveryScopeTests(unittest.TestCase):
    def test_startup_stays_map_cars_only(self):
        text = (ROOT / "project.godot").read_text(encoding="utf-8")
        match = re.search(r"\[autoload\]\n(.*?)(?:\n\[|\Z)", text, re.S)
        self.assertIsNotNone(match)
        names = []
        for raw in match.group(1).splitlines():
            line = raw.strip()
            if line and not line.startswith(";") and "=" in line:
                names.append(line.split("=", 1)[0].strip())
        self.assertEqual(names, ["MapQualityBootstrap"])

    def test_owner_catalog_defaults_to_crown_and_blocks_retired_cars(self):
        text = (ROOT / "scripts" / "vehicle_catalog.gd").read_text(encoding="utf-8")
        self.assertIn('const DEFAULT_ID := "toyota_crown"', text)
        self.assertIn('lowered == "toyota_mark_x"', text)
        self.assertIn('lowered.contains("992")', text)
        self.assertNotIn('PRODUCTION_IDS := ["toyota_crown", "toyota_mark_x"', text)

    def test_recovered_fleet_is_present(self):
        ids = []
        for name in ("vehicle_fleet_runtime.json", "vehicle_fleet_supplemental.json"):
            payload = json.loads((ROOT / "data" / name).read_text(encoding="utf-8"))
            ids.extend(str(item.get("id", "")) for item in payload.get("vehicles", []))
        ids = [item for item in ids if item]
        self.assertGreaterEqual(len(set(ids)), 17)
        self.assertNotIn("toyota_mark_x", ids)
        self.assertFalse(any("992" in item.lower() for item in ids))


if __name__ == "__main__":
    unittest.main()
