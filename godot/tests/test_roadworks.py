import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from build_roadworks import extract_roadworks, write_dataset


class Identity:
    def transform(self, x, y):
        return x, -y


def feature(identifier, points, **tags):
    return {
        "type": "Feature",
        "id": identifier,
        "properties": tags,
        "geometry": {"type": "LineString", "coordinates": points},
    }


class RoadworkTests(unittest.TestCase):
    def test_only_tagged_work_is_extracted_and_split_by_stream_tile(self):
        features = [
            feature("ordinary", [[0, 2], [25, 2]], highway="primary"),
            feature("work", [[0, 4], [25, 4]], highway="construction", construction="primary", lanes="2"),
        ]
        result = extract_roadworks(features, Identity(), (0, 0), 10.0)
        self.assertEqual(result["stats"]["features"], 1)
        self.assertEqual(result["stats"]["source_segments"], 1)
        self.assertEqual(result["stats"]["tile_pieces"], 3)
        self.assertEqual(set(result["tiles"]), {(0, 0), (1, 0), (2, 0)})
        records = [record for values in result["tiles"].values() for record in values]
        self.assertTrue(all(record["source_way"] == "work" for record in records))
        self.assertTrue(all(record["class"] == "primary" for record in records))
        self.assertTrue(all(record["width_m"] > 5.0 for record in records))

    def test_construction_tag_on_drivable_way_is_visual_metadata_only(self):
        result = extract_roadworks([
            feature("resurface", [[1, 1], [5, 1]], highway="secondary", construction="resurfacing", width="6.5 m"),
            feature("finished", [[1, 3], [5, 3]], highway="secondary", construction="no"),
        ], Identity(), (0, 0), 10.0)
        records = [record for values in result["tiles"].values() for record in values]
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["source_way"], "resurface")
        self.assertEqual(records[0]["class"], "secondary")
        self.assertEqual(records[0]["construction"], "resurfacing")
        self.assertEqual(records[0]["width_m"], 6.5)

    def test_geojson_writer_emits_empty_manifest_without_inventing_workzones(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "roads.geojson"
            source.write_text(json.dumps({
                "type": "FeatureCollection",
                "features": [feature("ordinary", [[-76.8, 18.0], [-76.79, 18.0]], highway="primary")],
            }), encoding="utf-8")
            output = root / "roadworks"
            manifest = write_dataset(source, output, 4096.0)
            self.assertEqual(manifest["stats"]["features"], 0)
            self.assertEqual(manifest["tiles"], [])
            self.assertEqual(manifest["purpose"], "visual-only OSM-tagged roadworks; never navigation authority")
            self.assertTrue((output / "manifest.json").is_file())

    def test_invalid_tile_size_is_rejected(self):
        with self.assertRaises(ValueError):
            extract_roadworks([], Identity(), (0, 0), 0.0)


if __name__ == "__main__":
    unittest.main()
