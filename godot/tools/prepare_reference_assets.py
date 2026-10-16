#!/usr/bin/env python3
"""Prepare imported owner-supplied media for mobile surfaces and exact PCM loops.

Run the Godot editor import once before this command, then import again after it.
The optional private pack is deliberately excluded from the public repository.
"""
from __future__ import annotations

import argparse
import re
from pathlib import Path


def prepare(root: Path) -> tuple[int, int]:
    media = sorted([*root.glob("*.png"), *root.glob("*.wav")])
    missing = [str(path.name) for path in media if not Path(str(path) + ".import").is_file()]
    if missing:
        raise ValueError("Run Godot editor import first; missing import settings: " + ", ".join(missing))
    changed = 0
    for path in media:
        settings = Path(str(path) + ".import")
        key, value = ("mipmaps/generate", "true") if path.suffix == ".png" else ("compress/mode", "0")
        before = settings.read_text(encoding="utf-8")
        after, count = re.subn(r"(?m)^" + re.escape(key) + r"=.*$", key + "=" + value, before)
        if count != 1:
            raise ValueError(f"Expected one {key} setting in {settings.name}, found {count}")
        if after != before:
            settings.write_text(after, encoding="utf-8")
            changed += 1
    return len(media), changed


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", nargs="?", type=Path,
                        default=Path(__file__).resolve().parents[1] / "assets" / "user_reference")
    args = parser.parse_args()
    media, changed = prepare(args.root)
    print(f"YARDMAN_REFERENCE_IMPORTS_PASS media={media} changed={changed}")


if __name__ == "__main__":
    main()
