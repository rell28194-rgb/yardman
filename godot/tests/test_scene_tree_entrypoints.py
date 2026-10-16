from __future__ import annotations

import re
import unittest
from pathlib import Path


TEST_ROOT = Path(__file__).resolve().parent
# Root SceneTree lifecycle methods are top-level GDScript functions. Requiring
# column-zero here deliberately ignores _init() methods inside nested helper
# classes, which are constructors rather than the script entrypoint.
SCENE_TREE_RE = re.compile(r"^extends\s+SceneTree\b", re.MULTILINE)
INITIALIZE_RE = re.compile(r"^func\s+_initialize\s*\(", re.MULTILINE)
INIT_RE = re.compile(r"^func\s+_init\s*\(", re.MULTILINE)
RUN_RE = re.compile(r"^func\s+_run\s*\(", re.MULTILINE)
NEXT_TOP_LEVEL_FUNC_RE = re.compile(r"^func\s+", re.MULTILINE)
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
            # Prefer the SceneTree-specific callback. _init() is accepted for
            # older tests, but only when it is a root-level script function.
            startup_match = INITIALIZE_RE.search(source) or INIT_RE.search(source)
            if startup_match is None:
                failures.append(f"{path.name}: extends SceneTree but has no root _initialize()/_init() startup callback")
                continue
            if RUN_RE.search(source):
                tail = source[startup_match.end():]
                next_func = NEXT_TOP_LEVEL_FUNC_RE.search(tail)
                startup_body = tail[: next_func.start()] if next_func else tail
                if not SCHEDULE_RUN_RE.search(startup_body):
                    failures.append(f"{path.name}: defines _run() but startup callback never schedules/calls it")

        self.assertGreater(checked, 0, "No SceneTree Godot tests were discovered")
        self.assertFalse(failures, "SceneTree test entrypoint contract failed:\n" + "\n".join(failures))


if __name__ == "__main__":
    unittest.main()
