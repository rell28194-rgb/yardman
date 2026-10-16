#!/usr/bin/env python3
"""Recover the RR3 packed range directly from Yardman's Beta2 split volumes.

This avoids rebuilding the complete ~12 GB Beta2 archive.  It streams only the
known RR3 byte interval spanning beta2.7z.083 through beta2.7z.200, validates
volume sizes while reading, and can split the recovered logical range into the
246 RR3 archive parts recorded by rr3-recovery-resume-001.json.

No recovered media is committed by this tool; outputs belong in private work
storage.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

OUTER_PART_BYTES = 52_428_800
FIRST_VOLUME = 83
LAST_VOLUME = 200
FIRST_RR3_GLOBAL_OFFSET = 4_307_473_099
LAST_RR3_PACK_OFFSET = 10_473_360_639
LAST_RR3_PACK_SIZE = 324_001
RR3_END_GLOBAL_OFFSET = LAST_RR3_PACK_OFFSET + LAST_RR3_PACK_SIZE
RR3_SPLIT_PART_BYTES = 25_165_824
RR3_STANDARD_PARTS = 245
RR3_TAIL_BYTES = 323_982
RR3_LOGICAL_BYTES = 6_165_950_862
EXPECTED_FIRST_SPLIT_SHA256 = "9d91a0fa764f492fecd4a0b73a378dfb09608ea3d5d81ba152cd342222ab8407"
EXPECTED_TAIL_SPLIT_SHA256 = "3fda833115117cd44b6e0594433a9349e5e671cef7d947c7602837c0c6d437b6"


def volume_path(root: Path, number: int, pattern: str) -> Path:
    return root / pattern.format(number=number)


def global_to_volume(offset: int) -> tuple[int, int]:
    volume = offset // OUTER_PART_BYTES + 1
    local = offset % OUTER_PART_BYTES
    return volume, local


def copy_interval(root: Path, output: Path, pattern: str, start: int, end: int, chunk: int) -> dict:
    if end <= start:
        raise ValueError("end must be greater than start")
    first_volume, first_local = global_to_volume(start)
    last_volume, last_local_end = global_to_volume(end - 1)
    last_local_end += 1
    if first_volume != FIRST_VOLUME or last_volume != LAST_VOLUME:
        raise ValueError(("unexpected RR3 volume span", first_volume, last_volume))

    output.parent.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha256()
    written = 0
    with output.open("wb") as dst:
        for number in range(first_volume, last_volume + 1):
            src_path = volume_path(root, number, pattern)
            if not src_path.is_file():
                raise FileNotFoundError(src_path)
            size = src_path.stat().st_size
            if number < LAST_VOLUME and size != OUTER_PART_BYTES:
                raise ValueError(("unexpected outer volume size", number, size, OUTER_PART_BYTES))
            begin = first_local if number == first_volume else 0
            finish = last_local_end if number == last_volume else size
            if finish > size:
                raise ValueError(("RR3 interval exceeds volume", number, finish, size))
            remaining = finish - begin
            with src_path.open("rb") as src:
                src.seek(begin)
                while remaining:
                    data = src.read(min(chunk, remaining))
                    if not data:
                        raise EOFError((src_path, remaining))
                    dst.write(data)
                    digest.update(data)
                    written += len(data)
                    remaining -= len(data)
    expected = end - start
    if written != expected:
        raise ValueError(("range-size mismatch", expected, written))
    return {
        "output": str(output),
        "bytes": written,
        "sha256": digest.hexdigest(),
        "first_volume": first_volume,
        "first_volume_offset": first_local,
        "last_volume": last_volume,
        "last_volume_end_offset": last_local_end,
    }


def split_rr3(logical: Path, dest: Path, prefix: str, chunk: int) -> dict:
    size = logical.stat().st_size
    if size != RR3_LOGICAL_BYTES:
        raise ValueError(("RR3 logical-size mismatch", RR3_LOGICAL_BYTES, size))
    dest.mkdir(parents=True, exist_ok=True)
    records = []
    with logical.open("rb") as src:
        for index in range(1, RR3_STANDARD_PARTS + 2):
            expected = RR3_SPLIT_PART_BYTES if index <= RR3_STANDARD_PARTS else RR3_TAIL_BYTES
            path = dest / f"{prefix}.{index:03d}"
            digest = hashlib.sha256()
            remaining = expected
            with path.open("wb") as out:
                while remaining:
                    data = src.read(min(chunk, remaining))
                    if not data:
                        raise EOFError((index, remaining))
                    out.write(data)
                    digest.update(data)
                    remaining -= len(data)
            records.append({"index": index, "path": str(path), "bytes": expected, "sha256": digest.hexdigest()})
        if src.read(1):
            raise ValueError("RR3 logical source has trailing bytes after split")
    first_ok = records[0]["sha256"] == EXPECTED_FIRST_SPLIT_SHA256
    tail_ok = records[-1]["sha256"] == EXPECTED_TAIL_SPLIT_SHA256
    if not first_ok or not tail_ok:
        raise ValueError(("RR3 split hash mismatch", first_ok, tail_ok))
    return {
        "parts": len(records),
        "logical_bytes": size,
        "first_sha256_verified": first_ok,
        "tail_sha256_verified": tail_ok,
        "first": records[0],
        "tail": records[-1],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("outer_root", type=Path, help="Directory containing beta2.7z.083 ... beta2.7z.200")
    parser.add_argument("--pattern", default="beta2.7z.{number:03d}")
    parser.add_argument("--output", type=Path, required=True, help="Private RR3 logical-range output")
    parser.add_argument("--split-dir", type=Path, help="Optionally emit the 246 RR3 split members")
    parser.add_argument("--split-prefix", default="com.ea.games.r3_row_xclipse.zip")
    parser.add_argument("--chunk-mib", type=int, default=8)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    chunk = max(1, args.chunk_mib) * 1024 * 1024

    report = {
        "source": "Beta2 outer volumes 83-200",
        "range": copy_interval(
            args.outer_root,
            args.output,
            args.pattern,
            FIRST_RR3_GLOBAL_OFFSET,
            RR3_END_GLOBAL_OFFSET,
            chunk,
        ),
    }
    if report["range"]["bytes"] != RR3_LOGICAL_BYTES:
        raise ValueError(("known RR3 range mismatch", RR3_LOGICAL_BYTES, report["range"]["bytes"]))
    if args.split_dir:
        report["split"] = split_rr3(args.output, args.split_dir, args.split_prefix, chunk)
    text = json.dumps(report, indent=2) + "\n"
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(text, encoding="utf-8")
    print(text, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
