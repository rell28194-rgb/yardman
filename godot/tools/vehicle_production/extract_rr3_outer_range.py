#!/usr/bin/env python3
"""Recover RR3 directly from Yardman's Beta2 split volumes.

The source interval is known to span beta2.7z.083 through beta2.7z.200.  This
implementation can write either one logical RR3 stream or the 246 recovered RR3
split members directly.  Direct split mode avoids creating a second ~6.2 GB
intermediate file and keeps memory bounded.

Recovered media belongs in private work storage and is never committed by this
tool.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import BinaryIO, Iterator

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
    return offset // OUTER_PART_BYTES + 1, offset % OUTER_PART_BYTES


def iter_interval(root: Path, pattern: str, start: int, end: int, chunk: int) -> Iterator[bytes]:
    if end <= start:
        raise ValueError("end must be greater than start")
    first_volume, first_local = global_to_volume(start)
    last_volume, last_local_end = global_to_volume(end - 1)
    last_local_end += 1
    if (first_volume, last_volume) != (FIRST_VOLUME, LAST_VOLUME):
        raise ValueError(("unexpected RR3 volume span", first_volume, last_volume))
    emitted = 0
    for number in range(first_volume, last_volume + 1):
        path = volume_path(root, number, pattern)
        if not path.is_file():
            raise FileNotFoundError(path)
        size = path.stat().st_size
        if number < LAST_VOLUME and size != OUTER_PART_BYTES:
            raise ValueError(("unexpected outer volume size", number, size, OUTER_PART_BYTES))
        begin = first_local if number == first_volume else 0
        finish = last_local_end if number == last_volume else size
        if finish > size:
            raise ValueError(("RR3 interval exceeds volume", number, finish, size))
        remaining = finish - begin
        with path.open("rb") as src:
            src.seek(begin)
            while remaining:
                data = src.read(min(chunk, remaining))
                if not data:
                    raise EOFError((path, remaining))
                emitted += len(data)
                remaining -= len(data)
                yield data
    expected = end - start
    if emitted != expected:
        raise ValueError(("range-size mismatch", expected, emitted))


def write_chunks(chunks: Iterator[bytes], output: BinaryIO) -> tuple[int, str]:
    digest = hashlib.sha256(); written = 0
    for data in chunks:
        output.write(data); digest.update(data); written += len(data)
    return written, digest.hexdigest()


def copy_interval(root: Path, output: Path, pattern: str, chunk: int) -> dict:
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("wb") as dst:
        written, sha256 = write_chunks(iter_interval(root, pattern, FIRST_RR3_GLOBAL_OFFSET, RR3_END_GLOBAL_OFFSET, chunk), dst)
    if written != RR3_LOGICAL_BYTES:
        raise ValueError(("known RR3 range mismatch", RR3_LOGICAL_BYTES, written))
    return {"output": str(output), "bytes": written, "sha256": sha256}


def direct_split(root: Path, dest: Path, pattern: str, prefix: str, chunk: int) -> dict:
    """Split the RR3 interval while streaming the outer volumes exactly once."""
    dest.mkdir(parents=True, exist_ok=True)
    source = iter_interval(root, pattern, FIRST_RR3_GLOBAL_OFFSET, RR3_END_GLOBAL_OFFSET, chunk)
    pending = b""; records = []; consumed = 0
    for index in range(1, RR3_STANDARD_PARTS + 2):
        expected = RR3_SPLIT_PART_BYTES if index <= RR3_STANDARD_PARTS else RR3_TAIL_BYTES
        path = dest / f"{prefix}.{index:03d}"
        digest = hashlib.sha256(); remaining = expected
        with path.open("wb") as out:
            while remaining:
                if not pending:
                    try: pending = next(source)
                    except StopIteration: raise EOFError(("RR3 source ended during split", index, remaining))
                take = min(remaining, len(pending)); data = pending[:take]; pending = pending[take:]
                out.write(data); digest.update(data); remaining -= take; consumed += take
        records.append({"index": index, "path": str(path), "bytes": expected, "sha256": digest.hexdigest()})
    try:
        extra = pending or next(source)
    except StopIteration:
        extra = b""
    if extra:
        raise ValueError("RR3 logical source has trailing bytes after split")
    if consumed != RR3_LOGICAL_BYTES:
        raise ValueError(("RR3 logical-size mismatch", RR3_LOGICAL_BYTES, consumed))
    first_ok = records[0]["sha256"] == EXPECTED_FIRST_SPLIT_SHA256
    tail_ok = records[-1]["sha256"] == EXPECTED_TAIL_SPLIT_SHA256
    if not first_ok or not tail_ok:
        raise ValueError(("RR3 split hash mismatch", first_ok, tail_ok))
    return {"parts": len(records), "logical_bytes": consumed, "first_sha256_verified": first_ok, "tail_sha256_verified": tail_ok, "first": records[0], "tail": records[-1]}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("outer_root", type=Path, help="Directory containing beta2.7z.083 ... beta2.7z.200")
    parser.add_argument("--pattern", default="beta2.7z.{number:03d}")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--output", type=Path, help="Write one private RR3 logical-range file")
    mode.add_argument("--split-dir", type=Path, help="Directly emit the 246 RR3 split members without a giant intermediate")
    parser.add_argument("--split-prefix", default="com.ea.games.r3_row_xclipse.zip")
    parser.add_argument("--chunk-mib", type=int, default=8)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args(); chunk = max(1, args.chunk_mib) * 1024 * 1024
    if args.output:
        result = {"mode": "logical_range", "range": copy_interval(args.outer_root, args.output, args.pattern, chunk)}
    else:
        result = {"mode": "direct_split", "split": direct_split(args.outer_root, args.split_dir, args.pattern, args.split_prefix, chunk)}
    result["source"] = {"first_volume": FIRST_VOLUME, "last_volume": LAST_VOLUME, "first_global_offset": FIRST_RR3_GLOBAL_OFFSET, "end_global_offset": RR3_END_GLOBAL_OFFSET, "logical_bytes": RR3_LOGICAL_BYTES}
    text = json.dumps(result, indent=2) + "\n"
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True); args.report.write_text(text, encoding="utf-8")
    print(text, end=""); return 0


if __name__ == "__main__":
    raise SystemExit(main())
