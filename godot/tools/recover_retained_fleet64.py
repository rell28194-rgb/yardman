#!/usr/bin/env python3
"""Recover the owner-private Fleet64 compiled cache without source GLBs.

The accepted Crown baseline and the later Fleet64 owner APK are both validated
build artifacts. Godot exports intentionally omit original GLB/image sources but
retain .import remaps and .godot/imported compiled resources. This helper
reconstructs that runtime cache for owner CI only; it does not write recovered
media into git.
"""

from __future__ import annotations

import argparse
import os
import shutil
import sys
import zipfile
from pathlib import Path


def copy_entry(archive: zipfile.ZipFile, info: zipfile.ZipInfo, project_root: Path) -> None:
    rel = info.filename[len("assets/") :]
    dst = project_root / rel
    dst.parent.mkdir(parents=True, exist_ok=True)
    with archive.open(info) as src, dst.open("wb") as out:
        shutil.copyfileobj(src, out, length=1024 * 1024)


def extract_apk_from_artifact(artifact: Path, apk_path: Path) -> None:
    with zipfile.ZipFile(artifact) as outer:
        apks = [name for name in outer.namelist() if name.endswith(".apk")]
        if len(apks) != 1:
            raise RuntimeError(f"expected one retained Fleet64 APK, found {apks!r}")
        with outer.open(apks[0]) as src, apk_path.open("wb") as out:
            shutil.copyfileobj(src, out, length=1024 * 1024)


def relevant_scene(path: Path) -> bool:
    name = path.name
    return name.endswith(".scn") and name.startswith(
        ("fleet_", "carx_", "toyota_crown_2013")
    )


def recover(base_apk: Path, fleet_artifact: Path, project_root: Path, fleet_apk: Path) -> dict[str, int]:
    user_reference = project_root / "assets" / "user_reference"
    imported_root = project_root / ".godot" / "imported"
    shutil.rmtree(user_reference, ignore_errors=True)
    shutil.rmtree(imported_root, ignore_errors=True)
    user_reference.mkdir(parents=True, exist_ok=True)
    imported_root.mkdir(parents=True, exist_ok=True)

    accepted_imported = 0
    accepted_reference = 0
    with zipfile.ZipFile(base_apk) as accepted:
        for info in accepted.infolist():
            if info.is_dir():
                continue
            name = info.filename
            if name.startswith("assets/.godot/imported/"):
                copy_entry(accepted, info, project_root)
                accepted_imported += 1
            elif name.startswith("assets/assets/user_reference/"):
                copy_entry(accepted, info, project_root)
                accepted_reference += 1

    extract_apk_from_artifact(fleet_artifact, fleet_apk)

    fleet_reference = 0
    fleet_imported = 0
    with zipfile.ZipFile(fleet_apk) as fleet:
        for info in fleet.infolist():
            if info.is_dir():
                continue
            name = info.filename
            if name.startswith("assets/assets/user_reference/"):
                copy_entry(fleet, info, project_root)
                fleet_reference += 1
            elif name.startswith("assets/.godot/imported/"):
                copy_entry(fleet, info, project_root)
                fleet_imported += 1

    vehicle_scenes = sum(1 for path in imported_root.glob("*.scn") if relevant_scene(path))
    glb_imports = sum(1 for _ in user_reference.glob("*.glb.import"))
    stats = {
        "accepted_imported": accepted_imported,
        "accepted_reference": accepted_reference,
        "fleet_reference": fleet_reference,
        "fleet_imported": fleet_imported,
        "vehicle_scenes": vehicle_scenes,
        "glb_imports": glb_imports,
    }

    required = [
        user_reference / "manifest.json",
        user_reference / "fleet_audi_r8.glb.import",
        user_reference / "toyota_crown_2013.glb.import",
    ]
    missing = [str(path) for path in required if not path.is_file() or path.stat().st_size == 0]
    if missing:
        raise RuntimeError(f"retained owner cache missing required remaps: {missing!r}")
    if fleet_reference < 700 or fleet_imported < 400:
        raise RuntimeError(f"retained Fleet64 cache incomplete: {stats!r}")
    if vehicle_scenes < 64:
        raise RuntimeError(f"combined accepted+Fleet64 vehicle scene cache incomplete: {stats!r}")
    if glb_imports < 64:
        raise RuntimeError(f"owner model remap inventory incomplete: {stats!r}")
    return stats


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-apk", required=True, type=Path)
    parser.add_argument("--fleet-artifact", required=True, type=Path)
    parser.add_argument("--project-root", required=True, type=Path)
    parser.add_argument("--fleet-apk", required=True, type=Path)
    args = parser.parse_args()
    try:
        stats = recover(args.base_apk, args.fleet_artifact, args.project_root, args.fleet_apk)
    except Exception as exc:
        print(f"YARDMAN_FLEET64_COMPILED_RECOVERY_FAIL {exc}", file=sys.stderr)
        return 1
    fields = " ".join(f"{key}={value}" for key, value in stats.items())
    print(f"YARDMAN_FLEET64_COMPILED_RECOVERY_PASS {fields}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
