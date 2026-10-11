"""Audit Gangstar resource families and recursively inspect private ZIP payloads.

Names are investigation labels, never accepted geometry or Jamaican geography.
The full manifest is private; the optional public report contains only counts,
hashes, format evidence, blockers and rejection scope. Source bytes are never
written to the public output. Original containers and decoded identities must
match the saved range inventory before their contents are inspected.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import ctypes
import ctypes.util
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import struct
import zipfile
import zlib

OWNER_CATEGORIES = (
    "vehicles", "vehicle_parts", "road_surfaces", "road_markings", "barriers",
    "signage", "buildings", "storefronts", "street_furniture", "vegetation",
    "terrain_coastal", "water", "props", "textures_materials", "characters",
    "animations", "hud_ui", "audio", "vfx", "shaders", "reference_systems",
)
PATTERNS = {
    "vehicles": r"(?:^|[_/])(?:car|bike|truck|taxi|bus|vehicle|boat|heli|plane)(?:[_./]|$)",
    "vehicle_parts": r"tire|tyre|wheel|bumper|exhaust|windshield|rim_|engine|car.*door",
    "road_surfaces": r"road|asphalt|junction|intersection|tarmac",
    "road_markings": r"crosswalk|lane.*(?:paint|mark)|road.*mark|zebra|road.*line",
    "barriers": r"barrier|guardrail|roadblock|bollard|curb|kerb|fence",
    "signage": r"sign|trafficlight|traffic_light",
    "buildings": r"building|house|tower|roof|facade|warehouse|diner|hotel|interior|district|city",
    "storefronts": r"shop|store|entrance|kiosk|bank|diner",
    "street_furniture": r"bench|hydrant|trashcan|mailbox|street.*(?:light|lamp)|busstop",
    "vegetation": r"tree|palm|bush|leaf|leaves|grass|plant|flower|forest",
    "terrain_coastal": r"ground|sand|rock|beach|cliff|terrain|coast|desert|mountain",
    "water": r"water|ocean|foam|shore|river|wave|caustic",
    "props": r"prop|crate|barrel|pallet|container|chair|table|furniture|trash|pipe|vent|tool",
    "textures_materials": r"texture|material|lightmap|atlas|diffuse|normalmap|\.tga$|\.ktx$",
    "characters": r"char_|character|pedestrian|skeleton|male_|female_|npc",
    "animations": r"anim|walk|idle|run_|jump|skeleton|rig",
    "hud_ui": r"hud|menu|touch|button|joystick|icon|font|\.ttf$|\.ttc$|\.swf$",
    "audio": r"\.wav$|\.mpc$|\.ogg$|\.vxvs$|\.vxn$|sound|audio",
    "vfx": r"vfx|effect|particle|smoke|dust|spark|flame|explosion|breakable",
    "shaders": r"shader|\.bar$|\.glsl$|\.vert$|\.frag$",
    "reference_systems": r"controller|manager|input|physics|camera|spline|world|behavior|\.glml$|\.hkt$|dependencies|batch_info",
}
FORMAT_CATEGORIES = {
    "KTX1": ["textures_materials"], "RIFF": ["audio"],
    "Musepack_SV8": ["audio"], "Ogg": ["audio"],
    "Vox_vehicle_audio": ["audio"], "Vox_audio": ["audio"],
    "SWF": ["hud_ui"], "TrueType": ["hud_ui"], "TrueTypeCollection": ["hud_ui"],
    "Localization_string_table": ["hud_ui"],
    "Havok_hkt": ["reference_systems"], "Gameloft_GLML_graph": ["reference_systems"],
    "Havok_packfile_signature": ["reference_systems"],
    "GLSL_source": ["shaders"], "COLLADA_XML": ["reference_systems"],
}
MAX_MEMBER = 256 * 1024 * 1024
MAX_ZIP_TOTAL = 2 * 1024 * 1024 * 1024
MAX_ZIP_ENTRIES = 100000


def format_of(head, name=""):
    for magic, format_name in (
        (b"BRES", "Gameloft_BRES"), (b"\xabKTX 11\xbb\r\n\x1a\n", "KTX1"),
        (b"PK\x03\x04", "ZIP"), (b"Voxarch", "Voxarch"),
        (b"MPCK", "Musepack_SV8"), (b"RIFF", "RIFF"), (b"OggS", "Ogg"),
        (b"Vxvs", "Vox_vehicle_audio"), (b"VoxN", "Vox_audio"),
        (b"\x1e\x0d\xb0\xca", "Havok_hkt"), (b"FWS", "SWF"),
        (b"\x57\xe0\xe0\x57\x10\xc0\xc0\x10", "Havok_packfile_signature"),
    ):
        if head.startswith(magic):
            return format_name
    if head.lstrip().startswith(b"<?xml") or head.lstrip().startswith(b"<COLLADA"):
        return "COLLADA_XML" if b"COLLADA" in head else "XML_or_markup_text"
    try:
        head.decode("utf8")
    except UnicodeDecodeError:
        return "unresolved"
    if name.lower().endswith(".glsl") and head.strip():
        return "GLSL_source"
    if name.lower().endswith((".txt", ".nfo")) and b"\0" not in head:
        return "text_resource"
    return "unresolved"


def family_stem(name):
    stem = PurePosixPath(name).stem.lower()
    # Keep numeric/prefab distinctions; only explicit representation suffixes
    # share a provisional name group. Parent/hierarchy relationships stay open.
    return re.sub(r"(?:_(?:diffuse|normal|normalmap|specular|alpha|albedo|lod\d+))+$", "", stem)


def classify(name, fmt, container=""):
    categories = {c for c, p in PATTERNS.items() if re.search(p, name, re.I)}
    categories.update(FORMAT_CATEGORIES.get(fmt, []))
    if fmt == "Gameloft_BRES" and re.search(r"(?:^|/)animations\.g4", container):
        categories.add("animations")
    if fmt in {"Voxarch", "ZIP"}:
        role = "container_requires_member_dispositions"
    elif fmt == "Gameloft_BRES":
        role = "model_or_animation_requires_semantic_parse"
    elif fmt in {"Havok_hkt", "Gameloft_GLML_graph", "Havok_packfile_signature", "GLSL_source", "COLLADA_XML"}:
        role = "reference_system_not_direct_godot_resource"
    elif fmt in FORMAT_CATEGORIES:
        role = "media_requires_decode_and_suitability_validation"
    else:
        role = "unresolved_format_or_support_resource"
    return {"candidate_categories": [c for c in OWNER_CATEGORIES if c in categories],
            "provisional_family": family_stem(name), "role": role,
            "category_absence_proven": False, "accepted": False}


def decode_range(data, kind, expected):
    if expected < 0 or expected > MAX_MEMBER:
        raise ValueError("Decoded member exceeds bounded budget")

    def plain(blob, mode, size):
        if mode == 0:
            return blob
        if mode == 1:
            import lz4.block
            return lz4.block.decompress(blob, uncompressed_size=size)
        if mode == 2:
            lib = ctypes.CDLL(ctypes.util.find_library("zstd"))
            lib.ZSTD_decompress.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t]
            lib.ZSTD_decompress.restype = ctypes.c_size_t
            lib.ZSTD_isError.argtypes = [ctypes.c_size_t]
            output = ctypes.create_string_buffer(size)
            actual = lib.ZSTD_decompress(output, size, blob, len(blob))
            if lib.ZSTD_isError(actual):
                raise ValueError("Zstd decoding error; legacy v0.6 support is required")
            return output.raw[:actual]
        raise ValueError("Unsupported storage kind")

    if kind & 0x200:
        if len(data) < 24:
            raise ValueError("Truncated OLYA header")
        magic, count, chunk_size, last_size, reserved1, reserved2 = struct.unpack_from("<4s5I", data)
        if magic != b"OLYA" or not 1 <= count <= 10000 or reserved1 or reserved2:
            raise ValueError("Invalid OLYA wrapper")
        if 24 + count * 8 > len(data) or (count - 1) * chunk_size + last_size > MAX_MEMBER:
            raise ValueError("OLYA table or output exceeds budget")
        chunks = []
        for i in range(count):
            start, length = struct.unpack_from("<II", data, 24 + i * 8)
            if start < 24 + count * 8 or start + length > len(data):
                raise ValueError("OLYA range outside member")
            size = last_size if i == count - 1 else chunk_size
            decoded = plain(data[start:start + length], kind & 0xff, size)
            if len(decoded) != size:
                raise ValueError("OLYA exact chunk length mismatch")
            chunks.append(decoded)
        result = b"".join(chunks)
    else:
        result = plain(data, kind, expected)
    if kind & 0xff and len(result) != expected:
        raise ValueError("Exact decoded length mismatch")
    return result


def inspect_zip(data, parent, depth=0):
    if depth > 4 or len(data) > MAX_MEMBER:
        raise ValueError("ZIP recursion or member budget exceeded")
    records = []
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        infos = archive.infolist()
        if len(infos) > MAX_ZIP_ENTRIES or sum(i.file_size for i in infos) > MAX_ZIP_TOTAL:
            raise ValueError("ZIP expanded entry budget exceeded")
        for index, info in enumerate(infos):
            identity = f"{parent}!{info.filename}#{index}"
            row = {"identity": identity, "parent": parent, "index": index,
                   "name": info.filename, "bytes": info.file_size, "crc32": f"{info.CRC:08x}",
                   "directory": info.is_dir(), "path_safe_for_extraction": not (
                       PurePosixPath(info.filename).is_absolute() or ".." in PurePosixPath(info.filename).parts
                       or "\\" in info.filename or re.match(r"^[A-Za-z]:", info.filename)),
                   "state": "pending", "accepted": False}
            if info.is_dir():
                row["state"] = "directory"
                records.append(row)
                continue
            if info.file_size > MAX_MEMBER:
                row.update(state="blocked", blocker="member exceeds bounded payload budget")
                records.append(row)
                continue
            digest = hashlib.sha256()
            prefix, nested, count = b"", None, 0
            try:
                with archive.open(info) as stream:
                    while blob := stream.read(1024 * 1024):
                        digest.update(blob)
                        count += len(blob)
                        if len(prefix) < 64:
                            prefix = (prefix + blob)[:64]
                        if count == len(blob) and blob.startswith(b"PK\x03\x04"):
                            nested = io.BytesIO()
                        if nested is not None:
                            nested.write(blob)
                if count != info.file_size:
                    raise ValueError("ZIP exact member size mismatch")
                fmt = format_of(prefix, info.filename)
                row.update(state="crc_sha_verified", sha256=digest.hexdigest(), format=fmt,
                           first_64_bytes_hex=prefix.hex(), **classify(info.filename, fmt, parent))
                if fmt == "ZIP":
                    records.extend(inspect_zip(nested.getvalue(), identity, depth + 1))
            except (ValueError, OSError, RuntimeError, zipfile.BadZipFile, zlib.error) as error:
                row.update(state="blocked", blocker=f"{type(error).__name__}: {error}")
            records.append(row)
    return records


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".working")
    with temporary.open("w", encoding="utf8") as output:
        json.dump(value, output, indent=2, ensure_ascii=False)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    temporary.replace(path)


def audit(index, output, apk=None, public_summary=None):
    rows, seen = [], set()
    with gzip.open(index, "rt", encoding="utf8") as stream:
        for line in stream:
            record = json.loads(line)
            identity = f"{record['container']}!{record['name']}#{record['index']}"
            if identity in seen:
                raise ValueError("Duplicate resource identity")
            seen.add(identity)
            decoded = record.get("decoded", {})
            row = {"identity": identity, "container": record["container"], "name": record["name"],
                   "index": record["index"], "raw_sha256": record["sha256"],
                   "decoded_sha256": decoded.get("sha256"), "decoded_bytes": decoded.get("bytes"),
                   "format": decoded.get("format", "unresolved"),
                   **classify(record["name"], decoded.get("format", "unresolved"), record["container"])}
            row["decode_status"] = record.get("decode_status", "unresolved")
            if row["format"] == "ZIP":
                if apk is None:
                    row.update(nested_inventory_state="blocked", blocker="private original APK not supplied")
                else:
                    try:
                        with Path(apk).open("rb") as source:
                            source.seek(record["absolute_apk_offset"])
                            raw = source.read(record["bytes"])
                        if len(raw) != record["bytes"] or hashlib.sha256(raw).hexdigest() != record["sha256"]:
                            raise ValueError("Original range identity mismatch")
                        payload = decode_range(raw, record["storage_kind"], record["declared_decoded_bytes"])
                        if len(payload) != decoded["bytes"] or hashlib.sha256(payload).hexdigest() != decoded["sha256"]:
                            raise ValueError("Decoded payload identity mismatch")
                        children = inspect_zip(payload, identity)
                        row.update(nested_inventory_state="verified" if all(c["state"] != "blocked" for c in children) else "blocked",
                                   nested_records=children)
                    except (ValueError, OSError, zipfile.BadZipFile) as error:
                        row.update(nested_inventory_state="blocked", blocker=f"{type(error).__name__}: {error}")
            rows.append(row)
    families = defaultdict(list)
    all_rows = rows + [r for row in rows for r in row.get("nested_records", []) if not r.get("directory")]
    for row in all_rows:
        families[row.get("provisional_family", "unresolved")].append(row["identity"])
    categories = {}
    for category in OWNER_CATEGORIES:
        members = [r for r in all_rows if category in r.get("candidate_categories", [])]
        categories[category] = {
            "candidate_records": len(members), "candidate_name_groups": len({r["provisional_family"] for r in members}),
            "extracted_families": 0, "technical_validation": "pending per-family dependencies and payload semantics",
            "visual_audio_validation": "pending", "integration_status": "pending", "review_complete": False,
            "category_absence_proven": False,
            "remaining_blockers": ["Name/format classification is candidate evidence; parent/dependency closure and suitability remain open."],
        }
    nested = [r for row in rows for r in row.get("nested_records", [])]
    summary = {
        "format_version": 1, "source_id": "gangstar4", "owner_categories": list(OWNER_CATEGORIES),
        "index_sha256": hashlib.sha256(Path(index).read_bytes()).hexdigest(),
        "original_resource_records": len(rows), "provisional_name_groups": len(families),
        "resource_formats": dict(Counter(r["format"] for r in rows)),
        "roles": dict(Counter(r["role"] for r in rows)),
        "uncategorized_records": sum(not r.get("candidate_categories") for r in all_rows),
        "nested_zip_resources": sum(r["format"] == "ZIP" for r in rows),
        "nested_zip_verified": sum(r.get("nested_inventory_state") == "verified" for r in rows),
        "nested_zip_blocked": sum(r.get("nested_inventory_state") == "blocked" for r in rows),
        "nested_member_records": len(nested),
        "nested_format_counts": dict(Counter(r.get("format", "directory") for r in nested)),
        "nested_payload_sha256": hashlib.sha256(json.dumps(nested, sort_keys=True).encode()).hexdigest(),
        "categories": categories, "family_semantics_complete": False,
        "accepted_families": 0, "beta1_complete": False, "beta2_allowed": False,
        "acceptance_boundary": "Complete record accounting and exact nested CRC/SHA evidence are inventory only. Unknown objects remain explicit; no name match accepts/rejects an asset or proves a category absent.",
    }
    atomic_json(output, {"summary": summary, "families": dict(families), "records": rows})
    if public_summary:
        atomic_json(public_summary, summary)
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("index", type=Path)
    parser.add_argument("--apk", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--public-summary", type=Path)
    args = parser.parse_args()
    result = audit(args.index, args.output, args.apk, args.public_summary)
    print(json.dumps({k: result[k] for k in ("original_resource_records", "provisional_name_groups", "nested_zip_resources", "nested_zip_verified", "nested_zip_blocked", "nested_member_records")}))


if __name__ == "__main__":
    main()
