#!/usr/bin/env python3
"""Random-access RR3 vehicle recovery from Yardman's 246-part Beta2 wrapper.

The RR3 7z payload is one solid LZMA2 stream, but it contains dictionary reset
chunks. This tool maps those reset boundaries, decodes only the final reset
window to read the inner ZIP64 central directory, and then decodes only the
reset window(s) that contain the requested vehicle's ZIP entries.

It avoids expanding the full ~6.31 GB inner ZIP just to recover one vehicle.
"""
from __future__ import annotations

import argparse
import binascii
import bisect
import collections
import hashlib
import json
import lzma
import shutil
import struct
import zlib
from pathlib import Path

PART_BYTES = 25_165_824
PARTS = 246
TAIL_BYTES = 323_982
LOGICAL_BYTES = 6_165_950_862
PACK_OFFSET = 32
PACK_SIZE = 6_165_950_692
UNPACKED_ZIP_BYTES = 6_310_079_877
DICT_BYTES = 67_108_864
PREFIX_DEFAULT = "com.ea.games.r3_row_xclipse.7z"
FIRST_SHA256 = "9d91a0fa764f492fecd4a0b73a378dfb09608ea3d5d81ba152cd342222ab8407"
TAIL_SHA256 = "3fda833115117cd44b6e0594433a9349e5e671cef7d947c7602837c0c6d437b6"
VEHICLE_PREFIX = "com.ea.games.r3_row_xclipse/com.ea.games.r3_row/files/.depot/vehicles/"


def sha256_file(path: Path, chunk: int = 8 * 1024 * 1024) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(chunk), b""):
            h.update(block)
    return h.hexdigest()


class SplitReader:
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
        self.pos = 0

    def seek(self, pos: int) -> None:
        if not 0 <= pos <= LOGICAL_BYTES:
            raise ValueError(("seek outside wrapper", pos))
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

    def read1(self) -> int:
        data = self.read(1)
        if not data:
            raise EOFError("unexpected end of split stream")
        return data[0]


def build_reset_map(arc: SplitReader) -> list[dict]:
    """Parse LZMA2 chunk framing without decompressing the payload."""
    arc.seek(PACK_OFFSET)
    packed_pos = 0
    unpacked_pos = 0
    resets: list[dict] = []

    while packed_pos < PACK_SIZE:
        control = arc.read1()
        packed_pos += 1
        if control == 0:
            if packed_pos != PACK_SIZE:
                raise ValueError(("early LZMA2 end marker", packed_pos, PACK_SIZE))
            break

        if control in (1, 2):
            size_bytes = arc.read(2)
            packed_pos += 2
            unpacked_size = int.from_bytes(size_bytes, "big") + 1
            if control == 1:
                resets.append({
                    "packed_offset": packed_pos - 3,
                    "unpacked_offset": unpacked_pos,
                    "control": control,
                    "kind": "uncompressed_dictionary_reset",
                })
            arc.seek(arc.pos + unpacked_size)
            packed_pos += unpacked_size
            unpacked_pos += unpacked_size
            continue

        if control < 0x80:
            raise ValueError(("invalid LZMA2 control", control, packed_pos - 1))

        header = arc.read(4)
        packed_pos += 4
        unpacked_size = ((control & 0x1F) << 16) + int.from_bytes(header[:2], "big") + 1
        compressed_size = int.from_bytes(header[2:], "big") + 1
        prop = None
        if control >= 0xC0:
            prop = arc.read1()
            packed_pos += 1
        if control >= 0xE0:
            resets.append({
                "packed_offset": packed_pos - 6,
                "unpacked_offset": unpacked_pos,
                "control": control,
                "kind": "compressed_dictionary_reset",
                "property": prop,
            })
        arc.seek(arc.pos + compressed_size)
        packed_pos += compressed_size
        unpacked_pos += unpacked_size

    if packed_pos != PACK_SIZE or unpacked_pos != UNPACKED_ZIP_BYTES:
        raise ValueError((
            "LZMA2 framing totals changed",
            packed_pos,
            PACK_SIZE,
            unpacked_pos,
            UNPACKED_ZIP_BYTES,
        ))
    if not resets or resets[0]["packed_offset"] != 0 or resets[0]["unpacked_offset"] != 0:
        raise ValueError("first LZMA2 chunk is no longer a dictionary reset")

    for i, item in enumerate(resets):
        item["segment_index"] = i
        item["packed_end"] = resets[i + 1]["packed_offset"] if i + 1 < len(resets) else PACK_SIZE
        item["unpacked_end"] = (
            resets[i + 1]["unpacked_offset"] if i + 1 < len(resets) else UNPACKED_ZIP_BYTES
        )
    return resets


def decode_segment(arc: SplitReader, reset: dict, chunk: int = 8 * 1024 * 1024) -> bytes:
    packed_start = reset["packed_offset"]
    packed_end = reset["packed_end"]
    expected = reset["unpacked_end"] - reset["unpacked_offset"]

    arc.seek(PACK_OFFSET + packed_start)
    remaining = packed_end - packed_start
    dec = lzma.LZMADecompressor(
        format=lzma.FORMAT_RAW,
        filters=[{"id": lzma.FILTER_LZMA2, "dict_size": DICT_BYTES}],
    )
    out = bytearray()

    while remaining and not dec.eof:
        data = arc.read(min(chunk, remaining))
        remaining -= len(data)
        feed = data
        while (feed or not dec.needs_input) and not dec.eof:
            raw = dec.decompress(feed if dec.needs_input else b"", max_length=16 * 1024 * 1024)
            feed = b""
            if raw:
                out.extend(raw)

    if not dec.eof:
        feed = b"\x00"
        while (feed or not dec.needs_input) and not dec.eof:
            raw = dec.decompress(feed if dec.needs_input else b"", max_length=16 * 1024 * 1024)
            feed = b""
            if raw:
                out.extend(raw)

    if remaining != 0 or not dec.eof or len(out) != expected:
        raise ValueError((
            "segment decode mismatch",
            reset["segment_index"],
            remaining,
            dec.eof,
            len(out),
            expected,
        ))
    return bytes(out)


def parse_zip64_central_directory(tail: bytes, tail_base: int) -> list[dict]:
    zip64_pos = tail.rfind(b"PK\x06\x06")
    if zip64_pos < 0:
        raise ValueError("ZIP64 EOCD not found in final reset segment")
    (
        _version_made,
        _version_needed,
        _disk,
        _cd_disk,
        _entries_disk,
        entries_total,
        cd_size,
        cd_offset,
    ) = struct.unpack_from("<HHIIQQQQ", tail, zip64_pos + 12)

    local = cd_offset - tail_base
    if local < 0 or local + cd_size > len(tail):
        raise ValueError(("central directory escapes final reset segment", cd_offset, cd_size))

    entries = []
    pos = local
    for index in range(entries_total):
        if tail[pos : pos + 4] != b"PK\x01\x02":
            raise ValueError(("bad central-directory signature", index, pos))
        (
            _version_made,
            _version_needed,
            flag,
            compression,
            _mtime,
            _mdate,
            crc,
            csize32,
            usize32,
            name_len,
            extra_len,
            comment_len,
            disk_start,
            _internal_attr,
            _external_attr,
            local_offset32,
        ) = struct.unpack_from("<HHHHHHIIIHHHHHII", tail, pos + 4)

        name_bytes = tail[pos + 46 : pos + 46 + name_len]
        name = name_bytes.decode("utf-8" if flag & 0x800 else "cp437", errors="replace")
        extra = tail[pos + 46 + name_len : pos + 46 + name_len + extra_len]

        csize = csize32
        usize = usize32
        local_offset = local_offset32
        if (
            csize32 == 0xFFFFFFFF
            or usize32 == 0xFFFFFFFF
            or local_offset32 == 0xFFFFFFFF
            or disk_start == 0xFFFF
        ):
            cursor = 0
            while cursor + 4 <= len(extra):
                header_id, body_len = struct.unpack_from("<HH", extra, cursor)
                cursor += 4
                body = extra[cursor : cursor + body_len]
                cursor += body_len
                if header_id != 0x0001:
                    continue
                q = 0
                if usize32 == 0xFFFFFFFF:
                    usize = struct.unpack_from("<Q", body, q)[0]
                    q += 8
                if csize32 == 0xFFFFFFFF:
                    csize = struct.unpack_from("<Q", body, q)[0]
                    q += 8
                if local_offset32 == 0xFFFFFFFF:
                    local_offset = struct.unpack_from("<Q", body, q)[0]
                    q += 8
                break

        entries.append({
            "path": name,
            "compressed_bytes": csize,
            "uncompressed_bytes": usize,
            "crc32": crc,
            "compression": compression,
            "local_header_offset": local_offset,
            "flag": flag,
        })
        pos += 46 + name_len + extra_len + comment_len

    if pos != local + cd_size:
        raise ValueError(("central-directory size mismatch", pos, local + cd_size))
    return entries


def vehicle_directories(entries: list[dict]) -> dict[str, int]:
    counts = collections.Counter()
    for entry in entries:
        path = entry["path"]
        if not path.startswith(VEHICLE_PREFIX):
            continue
        rest = path[len(VEHICLE_PREFIX) :]
        if not rest:
            continue
        vehicle = rest.split("/", 1)[0]
        if vehicle:
            counts[vehicle] += 1
    return dict(sorted(counts.items()))


def extract_vehicle(
    arc: SplitReader,
    resets: list[dict],
    entries: list[dict],
    vehicle: str,
    output_dir: Path,
) -> dict:
    wanted_prefix = f"{VEHICLE_PREFIX}{vehicle}/"
    wanted = [
        entry
        for entry in entries
        if entry["path"].startswith(wanted_prefix) and not entry["path"].endswith("/")
    ]
    if not wanted:
        raise KeyError(f"RR3 vehicle directory not found: {vehicle}")

    reset_outs = [item["unpacked_offset"] for item in resets]
    segment_cache: dict[int, bytes] = {}
    rows = []

    if output_dir.exists():
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    for entry in wanted:
        offset = entry["local_header_offset"]
        segment_index = bisect.bisect_right(reset_outs, offset) - 1
        if segment_index < 0:
            raise ValueError(("entry before first reset", entry["path"], offset))
        reset = resets[segment_index]
        if segment_index not in segment_cache:
            segment_cache[segment_index] = decode_segment(arc, reset)
        segment = segment_cache[segment_index]
        local = offset - reset["unpacked_offset"]

        if segment[local : local + 4] != b"PK\x03\x04":
            raise ValueError(("bad local header signature", entry["path"], offset))
        (
            _version_needed,
            _flag,
            _compression,
            _mtime,
            _mdate,
            _crc,
            _csize,
            _usize,
            name_len,
            extra_len,
        ) = struct.unpack_from("<HHHHHIIIHH", segment, local + 4)
        data_start = local + 30 + name_len + extra_len
        data_end = data_start + entry["compressed_bytes"]

        if data_end > len(segment):
            raise NotImplementedError(
                f"ZIP member crosses RR3 reset window: {entry['path']}"
            )
        compressed = segment[data_start:data_end]

        if entry["compression"] == 0:
            raw = compressed
        elif entry["compression"] == 8:
            raw = zlib.decompress(compressed, -15)
        else:
            raise NotImplementedError(
                ("unsupported inner ZIP compression", entry["compression"], entry["path"])
            )

        if len(raw) != entry["uncompressed_bytes"]:
            raise ValueError(("inner ZIP size mismatch", entry["path"]))
        crc = binascii.crc32(raw) & 0xFFFFFFFF
        if crc != entry["crc32"]:
            raise ValueError(("inner ZIP CRC mismatch", entry["path"], crc, entry["crc32"]))

        rel = entry["path"][len(wanted_prefix) :]
        dest = output_dir / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(raw)
        rows.append({
            "path": rel,
            "zip_local_header_offset": offset,
            "zip_compression": entry["compression"],
            "compressed_bytes": entry["compressed_bytes"],
            "uncompressed_bytes": entry["uncompressed_bytes"],
            "crc32": f"{crc:08x}",
            "sha256": hashlib.sha256(raw).hexdigest(),
            "rr3_reset_segment": segment_index,
        })

    return {
        "vehicle": vehicle,
        "file_count": len(rows),
        "uncompressed_bytes": sum(row["uncompressed_bytes"] for row in rows),
        "reset_segments_decoded": sorted(segment_cache),
        "files": rows,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("split_root", type=Path)
    parser.add_argument("--prefix", default=PREFIX_DEFAULT)
    parser.add_argument("--vehicle")
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--inventory-json", type=Path)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--skip-edge-hashes", action="store_true")
    args = parser.parse_args()

    arc = SplitReader(args.split_root, args.prefix)
    if not args.skip_edge_hashes:
        if sha256_file(arc.paths[0]) != FIRST_SHA256:
            raise ValueError("RR3 first split SHA-256 mismatch")
        if sha256_file(arc.paths[-1]) != TAIL_SHA256:
            raise ValueError("RR3 tail split SHA-256 mismatch")

    resets = build_reset_map(arc)
    tail_reset = resets[-1]
    tail = decode_segment(arc, tail_reset)
    entries = parse_zip64_central_directory(tail, tail_reset["unpacked_offset"])
    vehicles = vehicle_directories(entries)

    report = {
        "source": {
            "split_parts": PARTS,
            "wrapper_logical_bytes": LOGICAL_BYTES,
            "lzma2_packed_bytes": PACK_SIZE,
            "inner_zip_bytes": UNPACKED_ZIP_BYTES,
            "edge_hashes_verified": not args.skip_edge_hashes,
        },
        "random_access": {
            "lzma2_reset_segments": len(resets),
            "last_reset_packed_offset": tail_reset["packed_offset"],
            "last_reset_unpacked_offset": tail_reset["unpacked_offset"],
            "final_segment_unpacked_bytes": tail_reset["unpacked_end"] - tail_reset["unpacked_offset"],
        },
        "zip64_inventory": {
            "entry_count": len(entries),
            "vehicle_directory_count": len(vehicles),
        },
    }

    if args.inventory_json:
        args.inventory_json.parent.mkdir(parents=True, exist_ok=True)
        args.inventory_json.write_text(
            json.dumps({**report, "vehicle_directories": vehicles}, indent=2) + "\n",
            encoding="utf-8",
        )
        report["zip64_inventory"]["inventory_json"] = str(args.inventory_json)

    if args.vehicle:
        if args.output_dir is None:
            parser.error("--output-dir is required with --vehicle")
        report["extraction"] = extract_vehicle(
            arc, resets, entries, args.vehicle, args.output_dir
        )

    text = json.dumps(report, indent=2) + "\n"
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(text, encoding="utf-8")
    print(text, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
