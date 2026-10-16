#!/usr/bin/env python3
"""Sequentially decode Yardman's RR3 7z wrapper directly from 246 split parts.

The decoder validates known edge hashes, parses the 7z wrapper through a virtual
split reader, streams the single LZMA2 member into a private ZIP, and can emit a
complete central-directory inventory. No concatenated 7z staging file is needed.
"""
from __future__ import annotations

import argparse
import collections
import hashlib
import json
import lzma
import struct
import zipfile
import zlib
from pathlib import Path

from decode_sparse_7z import SIG, K_HEADER, parse_files_header, pack_offsets, lzma2_dict

PART_BYTES = 25_165_824
PARTS = 246
TAIL_BYTES = 323_982
LOGICAL_BYTES = 6_165_950_862
FIRST_SHA256 = "9d91a0fa764f492fecd4a0b73a378dfb09608ea3d5d81ba152cd342222ab8407"
TAIL_SHA256 = "3fda833115117cd44b6e0594433a9349e5e671cef7d947c7602837c0c6d437b6"


def sha256_file(path: Path, chunk: int = 8 * 1024 * 1024) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            data = f.read(chunk)
            if not data:
                break
            h.update(data)
    return h.hexdigest()


class SplitArchive:
    def __init__(self, root: Path, prefix: str):
        self.paths = [root / f"{prefix}.{i:03d}" for i in range(1, PARTS + 1)]
        missing = [str(p) for p in self.paths if not p.is_file()]
        if missing:
            raise FileNotFoundError(
                f"missing RR3 split parts: {missing[:8]}" + (" ..." if len(missing) > 8 else "")
            )
        for i, path in enumerate(self.paths, 1):
            expected = TAIL_BYTES if i == PARTS else PART_BYTES
            actual = path.stat().st_size
            if actual != expected:
                raise ValueError(("unexpected split size", i, actual, expected))
        if sha256_file(self.paths[0]) != FIRST_SHA256:
            raise ValueError("RR3 first split SHA-256 mismatch")
        if sha256_file(self.paths[-1]) != TAIL_SHA256:
            raise ValueError("RR3 tail split SHA-256 mismatch")
        self.pos = 0

    def seek(self, pos: int) -> None:
        if not 0 <= pos <= LOGICAL_BYTES:
            raise ValueError(("seek outside RR3 logical archive", pos))
        self.pos = pos

    def read(self, n: int) -> bytes:
        if n <= 0 or self.pos >= LOGICAL_BYTES:
            return b""
        n = min(n, LOGICAL_BYTES - self.pos)
        out = bytearray()
        while n:
            index = min(self.pos // PART_BYTES, PARTS - 1)
            local = self.pos - index * PART_BYTES
            path = self.paths[index]
            available = path.stat().st_size - local
            take = min(n, available)
            with path.open("rb") as f:
                f.seek(local)
                data = f.read(take)
            if len(data) != take:
                raise EOFError((path, local, take, len(data)))
            out.extend(data)
            self.pos += take
            n -= take
        return bytes(out)

    def read_exact_at(self, pos: int, n: int) -> bytes:
        self.seek(pos)
        data = self.read(n)
        if len(data) != n:
            raise EOFError((pos, n, len(data)))
        return data


def parse_wrapper(arc: SplitArchive) -> dict:
    h = arc.read_exact_at(0, 32)
    if h[:6] != SIG:
        raise ValueError(("bad 7z signature", h[:8].hex()))
    start_crc = struct.unpack("<I", h[8:12])[0]
    start = h[12:32]
    if (zlib.crc32(start) & 0xFFFFFFFF) != start_crc:
        raise ValueError("start-header CRC mismatch")
    next_offset, next_size, next_crc = struct.unpack("<QQI", start)
    next_header = arc.read_exact_at(32 + next_offset, next_size)
    if (zlib.crc32(next_header) & 0xFFFFFFFF) != next_crc:
        raise ValueError("next-header CRC mismatch")
    if not next_header or next_header[0] != K_HEADER:
        raise ValueError("RR3 wrapper next header is not a plain 7z header")

    parsed = parse_files_header(next_header)
    main = parsed["main"]
    if parsed["nfiles"] != 1 or len(parsed["names"]) != 1:
        raise ValueError(("unexpected RR3 wrapper file count", parsed["nfiles"], parsed["names"]))
    if not main or len(main["folders"]) != 1 or len(main["pack_sizes"]) != 1:
        raise ValueError("RR3 wrapper is no longer single-folder/single-pack")
    folder = main["folders"][0]
    if len(folder["coders"]) != 1 or folder["coders"][0]["method"] != b"\x21":
        raise ValueError(("unexpected RR3 compression", [c["method"].hex() for c in folder["coders"]]))
    props = folder["coders"][0]["props"]
    if len(props) != 1:
        raise ValueError(("unexpected LZMA2 properties", props.hex()))

    meta = {
        "name": parsed["names"][0],
        "pack_offset": pack_offsets(main)[0],
        "pack_size": main["pack_sizes"][0],
        "unpacked_size": main["unpack_sizes"][0][-1],
        "lzma2_property": props[0],
        "dictionary_bytes": lzma2_dict(props[0]),
        "next_header_offset": next_offset,
        "next_header_size": next_size,
    }
    if meta["pack_offset"] + meta["pack_size"] > LOGICAL_BYTES:
        raise ValueError(("packed stream exceeds logical wrapper", meta))
    return meta


def decode_member(arc: SplitArchive, meta: dict, output: Path, chunk: int) -> dict:
    output.parent.mkdir(parents=True, exist_ok=True)
    filt = {"id": lzma.FILTER_LZMA2, "dict_size": meta["dictionary_bytes"]}
    dec = lzma.LZMADecompressor(format=lzma.FORMAT_RAW, filters=[filt])
    arc.seek(meta["pack_offset"])
    remaining = meta["pack_size"]
    written = 0
    digest = hashlib.sha256()

    with output.open("wb") as out:
        while remaining and not dec.eof:
            data = arc.read(min(chunk, remaining))
            if not data:
                raise EOFError(("packed RR3 stream ended early", remaining))
            remaining -= len(data)
            feed = data
            while (feed or not dec.needs_input) and not dec.eof:
                raw = dec.decompress(feed if dec.needs_input else b"", max_length=chunk)
                feed = b""
                if raw:
                    out.write(raw)
                    digest.update(raw)
                    written += len(raw)

        while not dec.eof and not dec.needs_input:
            raw = dec.decompress(b"", max_length=chunk)
            if raw:
                out.write(raw)
                digest.update(raw)
                written += len(raw)

    if remaining != 0:
        raise ValueError(("LZMA2 reached EOF before declared packed bytes were consumed", remaining))
    if not dec.eof:
        raise ValueError("LZMA2 stream did not reach EOF after declared packed bytes")
    if written != meta["unpacked_size"]:
        raise ValueError(("decoded-size mismatch", meta["unpacked_size"], written))
    return {"output": str(output), "bytes": written, "sha256": digest.hexdigest()}


def inventory_zip(path: Path, output: Path, verify_crc: bool = False) -> dict:
    entries = []
    ext_counts = collections.Counter()
    total_uncompressed = 0
    total_compressed = 0

    with zipfile.ZipFile(path, "r") as zf:
        bad = zf.testzip() if verify_crc else None
        if bad is not None:
            raise ValueError(f"ZIP CRC failure: {bad}")
        for info in zf.infolist():
            suffix = Path(info.filename).suffix.lower() or "<none>"
            ext_counts[suffix] += 1
            total_uncompressed += info.file_size
            total_compressed += info.compress_size
            entries.append({
                "path": info.filename,
                "directory": info.is_dir(),
                "compressed_bytes": info.compress_size,
                "uncompressed_bytes": info.file_size,
                "crc32": f"{info.CRC:08x}",
                "compression": info.compress_type,
            })

    result = {
        "zip": str(path),
        "entry_count": len(entries),
        "total_uncompressed_bytes": total_uncompressed,
        "total_compressed_bytes": total_compressed,
        "extension_counts": dict(sorted(ext_counts.items())),
        "central_directory_readable": True,
        "full_crc_verified": verify_crc,
        "entries": entries,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return {k: v for k, v in result.items() if k != "entries"} | {"inventory": str(output)}


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("split_root", type=Path)
    p.add_argument("--prefix", default="com.ea.games.r3_row_xclipse.zip")
    p.add_argument("--output-zip", type=Path)
    p.add_argument(
        "--inspect-only",
        action="store_true",
        help="Validate split hashes and wrapper metadata without decoding the multi-GB member",
    )
    p.add_argument("--inventory", type=Path)
    p.add_argument("--report", type=Path)
    p.add_argument(
        "--verify-zip-crc",
        action="store_true",
        help="Expensive: reread/decompress every ZIP entry for CRC validation",
    )
    p.add_argument("--chunk-mib", type=int, default=8)
    args = p.parse_args()
    chunk = max(1, args.chunk_mib) * 1024 * 1024

    if not args.inspect_only and args.output_zip is None:
        p.error("--output-zip is required unless --inspect-only is used")
    if args.inspect_only and args.inventory:
        p.error("--inventory cannot be used with --inspect-only")

    arc = SplitArchive(args.split_root, args.prefix)
    meta = parse_wrapper(arc)
    report = {
        "source": {
            "split_parts": PARTS,
            "logical_bytes": LOGICAL_BYTES,
            "first_sha256_verified": True,
            "tail_sha256_verified": True,
        },
        "wrapper": meta,
        "mode": "inspect_only" if args.inspect_only else "decode",
    }

    if not args.inspect_only:
        report["decoded"] = decode_member(arc, meta, args.output_zip, chunk)
        if args.inventory:
            report["inventory"] = inventory_zip(
                args.output_zip, args.inventory, args.verify_zip_crc
            )

    text = json.dumps(report, indent=2) + "\n"
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(text, encoding="utf-8")
    print(text, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
