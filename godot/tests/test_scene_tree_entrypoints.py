from __future__ import annotations

import re
import unittest
from pathlib import Path


TEST_ROOT = Path(__file__).resolve().parent
SCENE_TREE_RE = re.compile(r"^\s*extends\s+SceneTree\b", re.MULTILINE)
STARTUP_RE = re.compile(r"^\s*func\s+_(?:initialize|init)\s*\(", re.MULTILINE)
RUN_RE = re.compile(r"^\s*func\s+_run\s*\(", re.MULTILINE)
SCHEDULE_RUN_RE = re.compile(r"(?:call_deferred\s*\(\s*[\"']_run[\"']|\b_run\s*\()")


class SceneTreeEntrypointContractTests(unittest.TestCase):
    """Prevent Godot --script smoke tests from silently idling until CI timeout."""

    def test_scene_tree_scripts_have_startup_entrypoints(self) -> None:
        failures: list[str] = []
        checked = 0
        for path in sorted(TEST_ROOT.glob("*.gd")):
            source = path.read_text(encoding="utf-8")
            if not SCENE_TREE_RE.search(source):
                continue
            checked += 1
            if not STARTUP_RE.search(source):
                failures.append(f"{path.name}: extends SceneTree but has no _initialize()/_init() startup callback")
                continue
            if RUN_RE.search(source):
                startup_match = STARTUP_RE.search(source)
                assert startup_match is not None
                tail = source[startup_match.end():]
                next_func = re.search(r"^\s*func\s+", tail, re.MULTILINE)
                startup_body = tail[: next_func.start()] if next_func else tail
                if not SCHEDULE_RUN_RE.search(startup_body):
                    failures.append(f"{path.name}: defines _run() but startup callback never schedules/calls it")

        self.assertGreater(checked, 0, "No SceneTree Godot tests were discovered")
        self.assertFalse(failures, "SceneTree test entrypoint contract failed:\n" + "\n".join(failures))


if __name__ == "__main__":
    unittest.main()
