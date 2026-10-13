import math
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from build_places import PLACE_KINDS, PARISH_CAPITALS, _dedupe, _nearest_parish, classify_place, is_capital


class PlaceCompilerTests(unittest.TestCase):
    def test_supported_named_place_types(self):
        for kind in PLACE_KINDS:
            self.assertEqual(classify_place({"place": kind, "name": "X"}), kind)
        self.assertEqual(classify_place({"place": "island", "name": "X"}), "")

    def test_named_pedestrian_area_is_square(self):
        self.assertEqual(classify_place({"highway": "pedestrian", "area": "yes", "name": "Sam Sharpe Square"}), "square")
        self.assertEqual(classify_place({"highway": "pedestrian", "name": "Unnamed area"}), "")

    def test_capital_tags_are_explicit(self):
        self.assertTrue(is_capital({"capital": "yes"}))
        self.assertTrue(is_capital({"capital": "4"}))
        self.assertFalse(is_capital({}))
        self.assertFalse(is_capital({"capital": "no"}))

    def test_parish_capital_fallback_covers_all_parishes(self):
        self.assertEqual(len(PARISH_CAPITALS), 14)
        self.assertEqual(PARISH_CAPITALS["St. James"][0], "Montego Bay")
        self.assertEqual(PARISH_CAPITALS["Manchester"][0], "Mandeville")
        self.assertEqual(PARISH_CAPITALS["Kingston"][0], "Kingston")

    def test_nearest_parish_uses_metric_world_position(self):
        anchors = {"A": (0.0, 0.0), "B": (1000.0, 0.0)}
        self.assertEqual(_nearest_parish(50.0, 20.0, anchors), "A")
        self.assertEqual(_nearest_parish(950.0, -10.0, anchors), "B")

    def test_dedupe_preserves_square_and_settlement_layers(self):
        records = [
            {"name": "Example", "kind": "town", "capital": False, "source": "node/1"},
            {"name": "Example", "kind": "town", "capital": True, "source": "node/2"},
            {"name": "Example", "kind": "square", "capital": False, "source": "way/3"},
        ]
        result = _dedupe(records)
        self.assertEqual(len(result), 2)
        town = next(r for r in result if r["kind"] == "town")
        self.assertTrue(town["capital"])


if __name__ == "__main__":
    unittest.main()
