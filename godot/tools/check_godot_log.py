#!/usr/bin/env python3
"""Fail CI on Godot runtime/compiler defects using one shared policy.

Benign warnings stay visible without making every workflow invent its own regex.
Callers may add subsystem-specific failure tokens such as ``FAIL``.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Iterable

CORE_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("script-error", re.compile(r"SCRIPT ERROR")),
    ("parse-error", re.compile(r"Parse Error")),
    ("unicode-parse-error", re.compile(r"Unicode parsing error")),
    ("godot-error", re.compile(r"^ERROR:")),
)


def scan_lines(lines: Iterable[str], extra_tokens: Iterable[str] = ()) -> list[tuple[int, str, str]]:
    tokens = tuple(token for token in extra_tokens if token)
    matches: list[tuple[int, str, str]] = []
    for line_number, raw_line in enumerate(lines, 1):
        line = raw_line.rstrip("\r\n")
        for label, pattern in CORE_PATTERNS:
            if pattern.search(line):
                matches.append((line_number, label, line))
                break
        else:
            for token in tokens:
                if token in line:
                    matches.append((line_number, f"token:{token}", line))
                    break
    return matches


def check_path(path: Path, extra_tokens: Iterable[str] = ()) -> int:
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError as error:
        print(f"GODOT_LOG_GUARD FAIL invalid-utf8 path={path} byte={error.start}", file=sys.stderr)
        return 2
    except OSError as error:
        print(f"GODOT_LOG_GUARD FAIL unreadable path={path}: {error}", file=sys.stderr)
        return 2

    matches = scan_lines(text.splitlines(), extra_tokens)
    if not matches:
        print(f"GODOT_LOG_GUARD PASS path={path}")
        return 0

    print(f"GODOT_LOG_GUARD FAIL path={path} matches={len(matches)}", file=sys.stderr)
    for line_number, label, line in matches:
        print(f"  L{line_number} [{label}] {line}", file=sys.stderr)
    return 1


def self_test() -> int:
    cases = (
        ("clean", ["Godot Engine v4.7.2", "WARNING: optional asset unavailable"], (), False),
        ("script", ["SCRIPT ERROR: bad index"], (), True),
        ("parse", ["Parse Error: Expected expression"], (), True),
        ("unicode", ["Unicode parsing error: Unexpected NUL character"], (), True),
        ("godot", ["ERROR: Condition failed"], (), True),
        ("token-off", ["YARDMAN_TEST FAIL reason"], (), False),
        ("token-on", ["YARDMAN_TEST FAIL reason"], ("FAIL",), True),
    )
    failures: list[str] = []
    for name, lines, tokens, should_fail in cases:
        failed = bool(scan_lines(lines, tokens))
        if failed != should_fail:
            failures.append(name)
    if failures:
        print("GODOT_LOG_GUARD_SELF_TEST FAIL cases=" + ",".join(failures), file=sys.stderr)
        return 1
    print("GODOT_LOG_GUARD_SELF_TEST PASS cases=%d" % len(cases))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", nargs="?", type=Path, help="UTF-8 Godot log to validate")
    parser.add_argument("--token", action="append", default=[], help="additional literal failure token (repeatable)")
    parser.add_argument("--self-test", action="store_true", help="run deterministic policy tests")
    args = parser.parse_args()
    if args.self_test:
        if args.log is not None or args.token:
            parser.error("--self-test cannot be combined with a log or --token")
        return self_test()
    if args.log is None:
        parser.error("log is required unless --self-test is used")
    return check_path(args.log, args.token)


if __name__ == "__main__":
    raise SystemExit(main())
