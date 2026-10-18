#!/usr/bin/env python3
"""Regression checks for source-tag truth in the national crossing inventory."""
from __future__ import annotations

import sys
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))

from build_hydrology_crossings import _source_bool


def main() -> int:
    # Explicit positive values remain usable evidence.
    assert _source_bool({"bridge": True}, "bridge")
    assert _source_bool({"bridge": "yes"}, "bridge")
    assert _source_bool({"tunnel": "1"}, "tunnel")
    assert _source_bool({"ford": "ford"}, "ford")
    assert _source_bool({"culvert": "culvert"}, "culvert")

    # Negative/absent OSM tags must never become structure evidence merely
    # because non-empty strings are truthy in Python.
    for value in (False, None, "", "no", "false", "0", "none"):
        assert not _source_bool({"bridge": value}, "bridge"), value
        assert not _source_bool({"tunnel": value}, "tunnel"), value

    # Aliases are checked without turning a negative primary tag into a veto of
    # separately preserved positive source evidence.
    assert _source_bool({"bridge": "no", "osm_bridge": "yes"}, "bridge", "osm_bridge")
    assert not _source_bool({"bridge": "no", "osm_bridge": "no"}, "bridge", "osm_bridge")

    print("YARDMAN_HYDROLOGY_CROSSING_INVENTORY_TEST_PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
