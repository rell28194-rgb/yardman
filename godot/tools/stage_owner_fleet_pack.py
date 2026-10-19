#!/usr/bin/env python3
import argparse
import hashlib
import json
import shutil
import sys
import zipfile
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]
CONTRACT_PATH = ROOT / "data" / "owner_fleet_pack_contract.json"
DEFAULT_DEST = ROOT / "assets" / "user_reference"
PRESERVE_SUFFIXES = {".tres", ".uid"}
PRESERVE_NAMES = {".gitkeep"}
STAMP_NAME = ".yardman-owner-pack.sha256"


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def safe_member(name: str) -> PurePosixPath:
    if "\\" in name:
        raise ValueError(f"unsafe zip member with backslash: {name}")
    p = PurePosixPath(name)
    if p.is_absolute() or ".." in p.parts or not p.parts:
        raise ValueError(f"unsafe zip member: {name}")
    return p


def stage(pack: Path, destination: Path, proof_path: Path | None = None) -> dict:
    contract = json.loads(CONTRACT_PATH.read_text(encoding="utf-8"))
    if int(contract.get("format_version", 0)) != 1:
        raise ValueError("unsupported owner fleet contract format")
    expected_bytes = int(contract["pack_bytes"])
    expected_sha = str(contract["pack_sha256"]).lower()
    actual_bytes = pack.stat().st_size
    actual_sha = sha256_file(pack)
    if actual_bytes != expected_bytes:
        raise ValueError(f"owner pack size mismatch: expected {expected_bytes}, got {actual_bytes}")
    if actual_sha != expected_sha:
        raise ValueError(f"owner pack SHA mismatch: expected {expected_sha}, got {actual_sha}")

    with zipfile.ZipFile(pack) as archive:
        bad_crc = archive.testzip()
        if bad_crc is not None:
            raise ValueError(f"owner pack CRC failure: {bad_crc}")
        if "manifest.json" not in archive.namelist():
            raise ValueError("owner pack manifest.json is missing")
        manifest_bytes = archive.read("manifest.json")
        manifest = json.loads(manifest_bytes)
        records = manifest.get("files", [])
        if not isinstance(records, list) or not records:
            raise ValueError("owner pack manifest has no files")

        declared: list[str] = []
        for record in records:
            name = str(record["path"])
            member = safe_member(name)
            data = archive.read(name)
            expected_record_bytes = int(record.get("bytes", len(data)))
            expected_record_sha = str(record["sha256"]).lower()
            actual_record_sha = hashlib.sha256(data).hexdigest()
            if len(data) != expected_record_bytes:
                raise ValueError(f"manifest byte mismatch for {name}")
            if actual_record_sha != expected_record_sha:
                raise ValueError(f"manifest SHA mismatch for {name}")
            declared.append(str(member))
        if len(declared) != len(set(declared)):
            raise ValueError("owner pack manifest contains duplicate paths")

        destination.mkdir(parents=True, exist_ok=True)
        stamp = destination / STAMP_NAME
        previous_sha = stamp.read_text(encoding="utf-8").strip().lower() if stamp.is_file() else ""
        same_pack = previous_sha == actual_sha
        # First/new-pack stage restores the complete verified archive, including
        # retained import metadata needed by some recovered source closures. Once
        # that exact pack has been imported, repeated stages preserve the current
        # Godot-generated import/dependency closure and refresh only source media.
        payload = declared if not same_pack else [name for name in declared if not name.endswith(".import")]
        removed = 0
        if not same_pack:
            # A different/unknown pack gets a clean private-media destination so
            # banned/obsolete hero bytes cannot leak forward. Project-owned TRES
            # and UID control files remain. The clean import will regenerate all
            # derived textures/dependencies and .import metadata.
            for path in sorted(destination.rglob("*"), reverse=True):
                if not path.is_file():
                    continue
                if path.suffix.lower() in PRESERVE_SUFFIXES or path.name in PRESERVE_NAMES:
                    continue
                path.unlink()
                removed += 1
        # For the same exact pack, keep importer-generated dependency closure.
        # Replacing only authoritative source bytes makes repeated validation
        # incremental without granting generated files authority over identity.
        for name in payload:
            member = safe_member(name)
            target = destination.joinpath(*member.parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(name) as source, target.open("wb") as output:
                shutil.copyfileobj(source, output, 1024 * 1024)
        (destination / "manifest.json").write_bytes(manifest_bytes)
        stamp.write_text(actual_sha + "\n", encoding="utf-8")

    proof = {
        "status": "PASS",
        "contract_format": int(contract["format_version"]),
        "pack": pack.name,
        "pack_bytes": actual_bytes,
        "pack_sha256": actual_sha,
        "same_pack_as_previous_stage": same_pack,
        "available_vehicle_count": int(contract["available_vehicle_count"]),
        "scrapped_vehicle_ids": contract["scrapped_vehicle_ids"],
        "held_missing_vehicle_ids": contract["held_missing_vehicle_ids"],
        "manifest_records": len(declared),
        "staged_source_records": len(payload),
        "stale_private_files_removed": removed,
        "destination": str(destination),
    }
    if proof_path is not None:
        proof_path.parent.mkdir(parents=True, exist_ok=True)
        proof_path.write_text(json.dumps(proof, indent=2) + "\n", encoding="utf-8")
    return proof


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify and stage the authoritative Yardman owner fleet pack.")
    parser.add_argument("pack", type=Path)
    parser.add_argument("--destination", type=Path, default=DEFAULT_DEST)
    parser.add_argument("--proof", type=Path)
    args = parser.parse_args()
    try:
        proof = stage(args.pack.resolve(), args.destination.resolve(), args.proof.resolve() if args.proof else None)
    except Exception as exc:
        print(f"YARDMAN_OWNER_FLEET_STAGE_FAIL {exc}", file=sys.stderr)
        return 1
    print("YARDMAN_OWNER_FLEET_STAGE_PASS " + json.dumps(proof, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
