#!/usr/bin/env python3
"""Random-access RR3 vehicle recovery from Yardman's 246-part Beta2 wrapper.

The recovered RR3 7z contains one ~6.31 GB ZIP in a solid LZMA2 stream. The
stream has verified dictionary-reset boundaries, so a requested vehicle can be
recovered by decoding only the reset windows that contain its ZIP records. ZIP
members that cross a reset boundary are stitched transparently.

Recovered vehicle media stays private. This public tool contains only source-
bound offsets, validation hashes, parsing logic and extraction machinery.
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
from typing import BinaryIO

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

# Source-bound LZMA2 dictionary-reset map. Each pair is
# (packed_offset_inside_the_LZMA2_member, unpacked_offset_inside_the_inner_ZIP).
# The framing parser below can independently rebuild/verify this map, but using
# the known map avoids rescanning all 6.16 GB for every single-car extraction.
RESET_PAIRS = (
    (0, 0),
    (261_270_479, 268_435_456),
    (514_612_745, 536_870_912),
    (771_669_779, 805_306_368),
    (1_035_773_937, 1_073_741_824),
    (1_299_736_906, 1_342_177_280),
    (1_554_833_906, 1_610_612_736),
    (1_823_270_918, 1_879_048_192),
    (2_091_588_963, 2_147_483_648),
    (2_359_936_655, 2_415_919_104),
    (2_623_702_336, 2_684_354_560),
    (2_892_018_922, 2_952_790_016),
    (3_154_892_330, 3_221_225_472),
    (3_419_847_372, 3_489_660_928),
    (3_684_974_977, 3_758_096_384),
    (3_950_754_907, 4_026_531_840),
    (4_216_653_647, 4_294_967_296),
    (4_481_315_515, 4_563_402_752),
    (4_742_841_206, 4_831_838_208),
    (5_004_631_132, 5_100_273_664),
    (5_266_103_479, 5_368_709_120),
    (5_526_380_481, 5_637_144_576),
    (5_786_490_008, 5_905_580_032),
    (6_043_996_989, 6_174_015_488),
)


def sha256_file(path: Path, chunk: int = 8 * 1024 * 1024) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(chunk), b""):
            digest.update(block)
    return digest.hexdigest()


class SplitReader:
    """Virtual seek/read over the 246 RR3 split volumes with cached handles."""

    def __init__(self, root: Path, prefix: str):
        self.paths = [root / f"{prefix}.{index:03d}" for index in range(1, PARTS + 1)]
        missing = [str(path) for path in self.paths if not path.is_file()]
        if missing:
            raise FileNotFoundError(
                f"missing RR3 split parts: {missing[:8]}" + (" ..." if len(missing) > 8 else "")
            )
        for index, path in enumerate(self.paths, 1):
            expected = TAIL_BYTES if index == PARTS else PART_BYTES
            actual = path.stat().st_size
            if actual != expected:
                raise ValueError(("unexpected split size", index, actual, expected))
        self.pos = 0
        self._handles: dict[int, BinaryIO] = {}

    def close(self) -> None:
        for handle in self._handles.values():
            handle.close()
        self._handles.clear()

    def _handle(self, index: int) -> BinaryIO:
        handle = self._handles.get(index)
        if handle is None:
            handle = self.paths[index].open("rb")
            self._handles[index] = handle
        return handle

    def seek(self, pos: int) -> None:
        if not 0 <= pos <= LOGICAL_BYTES:
            raise ValueError(("seek outside wrapper", pos))
        self.pos = pos

    def read(self, n: int) -> bytes:
        if n <= 0 or self.pos >= LOGICAL_BYTES:
            return b""
        n = min(n, LOGICAL_BYTES - self.pos)
        output = bytearray()
        while n:
            index = min(self.pos // PART_BYTES, PARTS - 1)
            local = self.pos - index * PART_BYTES
            available = self.paths[index].stat().st_size - local
            take = min(n, available)
            handle = self._handle(index)
            handle.seek(local)
            data = handle.read(take)
            if len(data) != take:
                raise EOFError((self.paths[index], local, take, len(data)))
            output.extend(data)
            self.pos += take
            n -= take
        return bytes(output)

    def read1(self) -> int:
        data = self.read(1)
        if not data:
            raise EOFError("unexpected end of split stream")
        return data[0]


def finalize_reset_map(pairs: list[tuple[int, int]] | tuple[tuple[int, int], ...]) -> list[dict]:
    resets = []
    for index, (packed_offset, unpacked_offset) in enumerate(pairs):
        next_packed = pairs[index + 1][0] if index + 1 < len(pairs) else PACK_SIZE
        next_unpacked = (
            pairs[index + 1][1]
            if index + 1 < len(pairs)
            else UNPACKED_ZIP_BYTES
        )
        resets.append({
            "segment_index": index,
            "packed_offset": packed_offset,
            "packed_end": next_packed,
            "unpacked_offset": unpacked_offset,
            "unpacked_end": next_unpacked,
        })
    return resets


def known_reset_map() -> list[dict]:
    return finalize_reset_map(RESET_PAIRS)


def rebuild_reset_map(arc: SplitReader) -> list[dict]:
    """Slow verification path: parse every LZMA2 chunk header without decoding."""
    arc.seek(PACK_OFFSET)
    packed_pos = 0
    unpacked_pos = 0
    pairs: list[tuple[int, int]] = []

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
                pairs.append((packed_pos - 3, unpacked_pos))
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
        if control >= 0xC0:
            arc.read1()
            packed_pos += 1
        if control >= 0xE0:
            pairs.append((packed_pos - 6, unpacked_pos))
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
    if tuple(pairs) != RESET_PAIRS:
        raise ValueError(("RR3 reset map changed", pairs))
    return finalize_reset_map(pairs)


def decode_segment(
    arc: SplitReader,
    reset: dict,
    chunk: int = 8 * 1024 * 1024,
) -> bytes:
    packed_start = reset["packed_offset"]
    packed_end = reset["packed_end"]
    expected = reset["unpacked_end"] - reset["unpacked_offset"]

    arc.seek(PACK_OFFSET + packed_start)
    remaining = packed_end - packed_start
    decoder = lzma.LZMADecompressor(
        format=lzma.FORMAT_RAW,
        filters=[{"id": lzma.FILTER_LZMA2, "dict_size": DICT_BYTES}],
    )
    output = bytearray()

    while remaining and not decoder.eof:
        data = arc.read(min(chunk, remaining))
        remaining -= len(data)
        feed = data
        while (feed or not decoder.needs_input) and not decoder.eof:
            raw = decoder.decompress(
                feed if decoder.needs_input else b"",
                max_length=16 * 1024 * 1024,
            )
            feed = b""
            if raw:
                output.extend(raw)

    # Intermediate reset windows do not contain the real LZMA2 end marker.
    # Appending one is valid because each window starts with a dictionary reset.
    if not decoder.eof:
        feed = b"\x00"
        while (feed or not decoder.needs_input) and not decoder.eof:
            raw = decoder.decompress(
                feed if decoder.needs_input else b"",
                max_length=16 * 1024 * 1024,
            )
            feed = b""
            if raw:
                output.extend(raw)

    if remaining != 0 or not decoder.eof or len(output) != expected:
        raise ValueError((
            "segment decode mismatch",
            reset["segment_index"],
            remaining,
            decoder.eof,
            len(output),
            expected,
        ))
    return bytes(output)


def zip_range(
    arc: SplitReader,
    resets: list[dict],
    reset_outs: list[int],
    cache: dict[int, bytes],
    offset: int,
    length: int,
) -> tuple[bytes, list[int]]:
    """Read an inner-ZIP byte range, stitching adjacent reset windows as needed."""
    if length < 0 or offset < 0 or offset + length > UNPACKED_ZIP_BYTES:
        raise ValueError(("ZIP range outside inner payload", offset, length))
    if length == 0:
        return b"", []

    cursor = offset
    end = offset + length
    output = bytearray()
    touched: list[int] = []

    while cursor < end:
        segment_index = bisect.bisect_right(reset_outs, cursor) - 1
        if segment_index < 0:
            raise ValueError(("range before first reset", cursor))
        reset = resets[segment_index]
        if cursor >= reset["unpacked_end"]:
            raise ValueError(("reset map gap", cursor, reset))
        if segment_index not in cache:
            cache[segment_index] = decode_segment(arc, reset)
        segment = cache[segment_index]
        local = cursor - reset["unpacked_offset"]
        take = min(end - cursor, reset["unpacked_end"] - cursor)
        output.extend(segment[local : local + take])
        if segment_index not in touched:
            touched.append(segment_index)
        cursor += take

    if len(output) != length:
        raise ValueError(("ZIP range short read", offset, length, len(output)))
    return bytes(output), touched


def parse_zip64_central_directory(tail: bytes, tail_base: int) -> tuple[list[dict], dict]:
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
        name = name_bytes.decode(
            "utf-8" if flag & 0x800 else "cp437",
            errors="replace",
        )
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
    return entries, {
        "entry_count": entries_total,
        "central_directory_offset": cd_offset,
        "central_directory_bytes": cd_size,
    }


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
    cache: dict[int, bytes] | None = None,
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
    segment_cache = cache if cache is not None else {}
    rows = []

    if output_dir.exists():
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    for entry in wanted:
        offset = entry["local_header_offset"]
        local_header, header_segments = zip_range(
            arc, resets, reset_outs, segment_cache, offset, 30
        )
        if local_header[:4] != b"PK\x03\x04":
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
        ) = struct.unpack_from("<HHHHHIIIHH", local_header, 4)

        data_start = offset + 30 + name_len + extra_len
        compressed, data_segments = zip_range(
            arc,
            resets,
            reset_outs,
            segment_cache,
            data_start,
            entry["compressed_bytes"],
        )

        if entry["compression"] == 0:
            raw = compressed
        elif entry["compression"] == 8:
            raw = zlib.decompress(compressed, -15)
        else:
            raise NotImplementedError((
                "unsupported inner ZIP compression",
                entry["compression"],
                entry["path"],
            ))

        if len(raw) != entry["uncompressed_bytes"]:
            raise ValueError(("inner ZIP size mismatch", entry["path"]))
        crc = binascii.crc32(raw) & 0xFFFFFFFF
        if crc != entry["crc32"]:
            raise ValueError(("inner ZIP CRC mismatch", entry["path"], crc, entry["crc32"]))

        rel = entry["path"][len(wanted_prefix) :]
        dest = output_dir / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(raw)
        touched = sorted(set(header_segments + data_segments))
        rows.append({
            "path": rel,
            "zip_local_header_offset": offset,
            "zip_compression": entry["compression"],
            "compressed_bytes": entry["compressed_bytes"],
            "uncompressed_bytes": entry["uncompressed_bytes"],
            "crc32": f"{crc:08x}",
            "sha256": hashlib.sha256(raw).hexdigest(),
            "rr3_reset_segments": touched,
            "crosses_reset_window": len(touched) > 1,
        })

    return {
        "vehicle": vehicle,
        "file_count": len(rows),
        "uncompressed_bytes": sum(row["uncompressed_bytes"] for row in rows),
        "reset_segments_decoded": sorted(segment_cache),
        "cross_window_file_count": sum(
            1 for row in rows if row["crosses_reset_window"]
        ),
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
    parser.add_argument(
        "--rebuild-reset-map",
        action="store_true",
        help="Slow verification mode: rescan all LZMA2 chunk headers and compare the known reset map",
    )
    args = parser.parse_args()

    arc = SplitReader(args.split_root, args.prefix)
    try:
        if not args.skip_edge_hashes:
            if sha256_file(arc.paths[0]) != FIRST_SHA256:
                raise ValueError("RR3 first split SHA-256 mismatch")
            if sha256_file(arc.paths[-1]) != TAIL_SHA256:
                raise ValueError("RR3 tail split SHA-256 mismatch")

        resets = rebuild_reset_map(arc) if args.rebuild_reset_map else known_reset_map()
        tail_reset = resets[-1]
        cache: dict[int, bytes] = {}
        cache[tail_reset["segment_index"]] = decode_segment(arc, tail_reset)
        tail = cache[tail_reset["segment_index"]]
        entries, cd_meta = parse_zip64_central_directory(
            tail,
            tail_reset["unpacked_offset"],
        )
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
                "reset_map_source": (
                    "full_framing_rescan_verified"
                    if args.rebuild_reset_map
                    else "source_bound_verified_map"
                ),
                "last_reset_packed_offset": tail_reset["packed_offset"],
                "last_reset_unpacked_offset": tail_reset["unpacked_offset"],
                "final_segment_unpacked_bytes": (
                    tail_reset["unpacked_end"] - tail_reset["unpacked_offset"]
                ),
                "cross_reset_zip_members_supported": True,
            },
            "zip64_inventory": {
                **cd_meta,
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
                arc,
                resets,
                entries,
                args.vehicle,
                args.output_dir,
                cache,
            )

        text = json.dumps(report, indent=2) + "\n"
        if args.report:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(text, encoding="utf-8")
        print(text, end="")
        return 0
    finally:
        arc.close()


if __name__ == "__main__":
    raise SystemExit(main())
