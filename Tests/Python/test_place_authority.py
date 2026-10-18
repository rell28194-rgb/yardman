from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "godot" / "tools"))

from enforce_place_authority import enforce_manifest


class PlaceAuthorityTests(unittest.TestCase):
    def test_guessed_and_synthetic_records_never_enter_runtime_tiles(self):
        source = {
            "tiles": {
                "0:0": [
                    {"name": "Authoritative", "kind": "town", "parish": "Kingston", "parish_assignment": "admin_level_6_polygon", "source": "node/1"},
                    {"name": "Unresolved", "kind": "village", "parish": "St. Andrew", "parish_assignment": "nearest_capital_fallback", "source": "node/2"},
                    {"name": "Synthetic", "kind": "parish_capital", "parish": "Portland", "parish_assignment": "canonical_capital_fallback", "source": "fallback/Portland"},
                    {"name": "Blank", "kind": "locality", "parish": "", "parish_assignment": "", "source": "node/3"},
                ]
            },
            "stats": {"raw_places": 4},
        }
        cleaned = enforce_manifest(source)
        runtime = cleaned["tiles"]["0:0"]
        self.assertEqual([record["name"] for record in runtime], ["Authoritative"])
        self.assertEqual(cleaned["stats"]["places"], 1)
        self.assertEqual(cleaned["stats"]["unresolved_source_records"], 2)
        self.assertEqual(cleaned["stats"]["dropped_synthetic_records"], 1)
        self.assertEqual(cleaned["stats"]["parish_assignment"], {"admin_level_6_polygon": 1})
        unresolved = {record["name"]: record for record in cleaned["unresolved_places"]}
        self.assertEqual(unresolved["Unresolved"]["parish"], "")
        self.assertEqual(unresolved["Unresolved"]["parish_assignment"], "unresolved_admin_boundary")
        self.assertIn("fallback/Portland", cleaned["authority_cleanup"]["dropped_synthetic_sources"])

    def test_malformed_tiles_fail_closed(self):
        with self.assertRaises(ValueError):
            enforce_manifest({"tiles": []})
        with self.assertRaises(ValueError):
            enforce_manifest({"tiles": {"0:0": {}}})


if __name__ == "__main__":
    unittest.main()
