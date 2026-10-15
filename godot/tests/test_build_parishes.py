import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from build_parishes import PARISHES, canonical_parish_name, project_boundaries


class IdentityTransformer:
    def transform(self, lon, lat):
        return float(lon), float(lat)


class ParishCompilerTests(unittest.TestCase):
    def test_all_fourteen_canonical_parishes_present(self):
        self.assertEqual(len(PARISHES), 14)
        self.assertIn("Kingston", PARISHES)
        self.assertIn("St. Thomas", PARISHES)

    def test_name_normalization(self):
        self.assertEqual(canonical_parish_name("Saint Andrew Parish"), "St. Andrew")
        self.assertEqual(canonical_parish_name({"official_name": "Saint Elizabeth Parish"}), "St. Elizabeth")
        self.assertEqual(canonical_parish_name("Jamaica"), "")

    def test_projection_preserves_outer_ring_hole_and_bounds(self):
        geometry = {
            "type": "Polygon",
            "coordinates": [
                [[10.0, 20.0], [20.0, 20.0], [20.0, 30.0], [10.0, 30.0], [10.0, 20.0]],
                [[13.0, 23.0], [17.0, 23.0], [17.0, 27.0], [13.0, 27.0], [13.0, 23.0]],
            ],
        }
        boundaries = {name: [geometry] for name in PARISHES}
        projected = project_boundaries(boundaries, IdentityTransformer(), (0.0, 40.0))
        self.assertEqual(set(projected), set(PARISHES))
        sample = projected["Kingston"][0]
        self.assertEqual(sample["bounds"], [10.0, 10.0, 20.0, 20.0])
        self.assertEqual(len(sample["rings"]), 2)
        self.assertEqual(sample["rings"][0][0], [10.0, 20.0])
        self.assertEqual(sample["rings"][0][-1], sample["rings"][0][0])

    def test_missing_parish_fails_closed(self):
        geometry = {
            "type": "Polygon",
            "coordinates": [[[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0], [0.0, 0.0]]],
        }
        with self.assertRaises(RuntimeError):
            project_boundaries({"Kingston": [geometry]}, IdentityTransformer(), (0.0, 0.0))


if __name__ == "__main__":
    unittest.main()
