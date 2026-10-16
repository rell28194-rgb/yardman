import ast
import unittest
from pathlib import Path


class RoadAuxiliaryBuildContractTests(unittest.TestCase):
    def _function_strings(self, name: str) -> set[str]:
        source_path = Path(__file__).resolve().parents[1] / "tools" / "build_jamaica_roads.py"
        tree = ast.parse(source_path.read_text(encoding="utf-8"), filename=str(source_path))
        function = next(
            node for node in tree.body
            if isinstance(node, ast.FunctionDef) and node.name == name
        )
        return {
            node.value for node in ast.walk(function)
            if isinstance(node, ast.Constant) and isinstance(node.value, str)
        }

    def test_canonical_road_build_regenerates_engineering_evidence(self):
        strings = self._function_strings("build_auxiliary_layers")
        for tool in ("build_roadworks.py", "build_drainage.py", "build_guardrails.py"):
            self.assertIn(tool, strings)
        for directory in ("roadworks", "drainage", "guardrails"):
            self.assertIn(directory, strings)

    def test_national_context_layers_remain_in_same_build(self):
        strings = self._function_strings("build_auxiliary_layers")
        for tool in (
            "build_places.py",
            "build_parishes.py",
            "build_bus_stops.py",
            "build_retaining_walls.py",
        ):
            self.assertIn(tool, strings)


if __name__ == "__main__":
    unittest.main()
