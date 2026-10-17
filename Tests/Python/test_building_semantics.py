import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "godot" / "tools"))

from building_semantics import (
    declared_shell_family,
    grammar_profile,
    inherit_declared_envelope,
    material_family,
    reconstruction_confidence,
    source_envelope,
    use_class,
)


class BuildingSemanticsTests(unittest.TestCase):
    def test_zinc_and_corrugated_are_first_class_metal_envelope(self):
        self.assertEqual(material_family("zinc"), "metal")
        self.assertEqual(material_family("corrugated_metal"), "metal")
        self.assertEqual(material_family("galvanized_steel"), "metal")
        result = source_envelope({"building:cladding": "corrugated_metal", "roof:material": "zinc"})
        self.assertEqual(result["wall_material"], "metal")
        self.assertEqual(result["roof_material"], "metal")
        self.assertEqual(result["wall_material_raw"], "corrugated_metal")
        self.assertEqual(result["roof_material_raw"], "zinc")
        self.assertEqual(result["declared_shell_family"], "metal_clad_lightweight")

    def test_mixed_envelopes_remain_mixed(self):
        result = source_envelope({"building:material": "wood", "roof:material": "sheet_metal"})
        self.assertEqual(result["wall_material"], "timber")
        self.assertEqual(result["roof_material"], "metal")
        self.assertEqual(result["declared_shell_family"], "timber_metal")
        self.assertEqual(declared_shell_family("concrete", "zinc"), "masonry_metal")

    def test_parent_evidence_only_fills_missing_part_tags(self):
        parent = {"building:material": "concrete", "roof:material": "zinc", "building:colour": "cream", "tourism": "hotel"}
        child = {"building:part": "yes", "building:material": "wood"}
        merged = inherit_declared_envelope(child, parent)
        self.assertEqual(merged["building:material"], "wood")
        self.assertEqual(merged["roof:material"], "zinc")
        self.assertEqual(merged["building:colour"], "cream")
        self.assertEqual(merged["tourism"], "hotel")

    def test_confidence_tiers_follow_reconstruction_spec(self):
        self.assertEqual(reconstruction_confidence({"building": "yes"}), "B0")
        self.assertEqual(reconstruction_confidence({"building": "house"}), "B1")
        self.assertEqual(reconstruction_confidence({"building": "house", "roof:shape": "hipped"}), "B2")
        self.assertEqual(reconstruction_confidence({"building:part": "yes"}, True), "B3")

    def test_unknown_material_is_preserved_not_randomized(self):
        result = source_envelope({"building:material": "wattle_and_daub"})
        self.assertEqual(result["wall_material"], "wattle_and_daub")
        self.assertEqual(result["wall_material_raw"], "wattle_and_daub")

    def test_use_context_outranks_generic_building_yes(self):
        self.assertEqual(use_class({"building": "yes", "amenity": "school"}), "education")
        self.assertEqual(use_class({"building": "yes", "tourism": "hotel"}), "lodging")
        self.assertEqual(use_class({"building": "yes", "shop": "supermarket"}), "retail")
        self.assertEqual(use_class({"building": "apartments"}), "residential_multi")
        self.assertEqual(grammar_profile({"building": "yes", "amenity": "school"}), "jamaica_education_v0_1")
        self.assertEqual(grammar_profile({"building": "house"}), "jamaica_residential_v0_1")

    def test_source_envelope_keeps_construction_state(self):
        result = source_envelope({"building": "construction", "construction": "house"})
        self.assertEqual(result["construction_state"], "house")


if __name__ == "__main__":
    unittest.main()
