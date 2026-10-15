#!/usr/bin/env python3
"""Run isolated Godot material-role checks using generated PNG controls only.

This validates loader/material logic, not rendered or Android-device quality.
It never copies recovered media or changes the production reference directory.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile
import zlib


ERRORS = re.compile(r"SCRIPT ERROR|Parse Error|(?:^|\n)ERROR:|_CASE FAIL")
PRELOAD = re.compile(r'''\bpreload\s*\(\s*["']res://([^"']+)["']\s*\)''')
CASES = ("asset-absent", "original-only", "approved-alternate", "tampered-alternate")
FIXTURE = '''extends SceneTree
const References = preload("res://scripts/reference_assets.gd")
const Visuals = preload("res://scripts/world_visuals.gd")
var failures := 0

func check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("REFERENCE_ROLE: " + message)

func _initialize() -> void:
    var case := OS.get_environment("YARDMAN_ROLE_CASE")
    var original: Texture2D = null
    if case != "asset-absent":
        original = ResourceLoader.load(References.ROOT + "ground_rock.png") as Texture2D
        check(original != null, "generated original did not import")
    var selected := References.texture("ground_rock.png")
    var material := Visuals.new().terrain_material(Vector2(-32768, 8192))
    check(material.get_shader_parameter("tile_origin") == Vector2(-32768, 8192), "canonical tile origin lost")
    if case == "approved-alternate":
        var approved := References.texture("ground_rock_alternate.png")
        check(approved != null and selected == approved and selected != original, "approved alternate not selected distinctly")
        check(material.get_shader_parameter("has_reference_rock") == true, "approved rock disabled")
        check(material.get_shader_parameter("reference_rock") == approved, "terrain did not bind approved rock")
        check(material.get_shader_parameter("has_reference_ground") == true, "grass/dry controls disabled")
        for binding in [["reference_grass", "ground_grass.png"], ["reference_dry_grass", "ground_dry_grass.png"]]:
            check(material.get_shader_parameter(binding[0]) == References.texture(binding[1]), "ground role binding changed")
    else:
        check(selected == null, "rejected original loaded instead of procedural rock")
        if case == "tampered-alternate":
            check(References.texture("ground_rock_alternate.png") == null, "changed source bytes bypassed the manifest")
        check(material.get_shader_parameter("has_reference_rock") != true, "missing approved rock enabled reference sampling")
        check(material.get_shader_parameter("reference_rock") == null, "procedural fallback retained texture")
    print("YARDMAN_REFERENCE_ROLE_CASE %s case=%s" % ["PASS" if failures == 0 else "FAIL", case])
    quit(0 if failures == 0 else 1)
'''


def generated_png(color: tuple[int, int, int]) -> bytes:
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    rows = b"".join(b"\0" + bytes(color) * 16 for _ in range(16))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 16, 16, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def production_sources(project: Path) -> dict[str, bytes]:
    result: dict[str, bytes] = {}
    pending = ["scripts/reference_assets.gd", "scripts/world_visuals.gd"]
    while pending:
        relative = pending.pop()
        if relative in result:
            continue
        path = (project / relative).resolve()
        if not path.is_relative_to(project) or "assets" in Path(relative).parts:
            raise ValueError(f"Fixture dependency must be public source: {relative}")
        data = path.read_bytes()
        result[relative] = data
        pending.extend(PRELOAD.findall(data.decode("utf-8")))
    return result


def engine(command: list[str], environment: dict[str, str], timeout: float) -> tuple[int, str]:
    try:
        r = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout + r.stderr
    except subprocess.TimeoutExpired:
        return 124, "VALIDATOR ERROR: Godot timed out.\n"


def run_case(executable: str, root: Path, sources: dict[str, bytes], case: str,
             evidence: Path | None, timeout: float, mutation: bool = False) -> dict:
    name = "mutation-original-only" if mutation else case
    fixture = root / name
    fixture.mkdir()
    for relative, payload in sources.items():
        if mutation and relative == "scripts/reference_assets.gd":
            text, count = re.subn(r"(?m)^const STRICT_TEXTURE_UPGRADES := \[[^\n]*\]$",
                                 "const STRICT_TEXTURE_UPGRADES := []", payload.decode())
            if count != 1:
                raise ValueError("Strict-alias control mutation could not be applied")
            payload = text.encode()
        path = fixture / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(payload)
    (fixture / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Yardman role fixture"\n'
        '[rendering]\nrenderer/rendering_method="gl_compatibility"\n')
    (fixture / "fixture.gd").write_text(FIXTURE)
    controls = {} if case == "asset-absent" else {"ground_rock.png": (245, 245, 245)}
    if case in ("approved-alternate", "tampered-alternate"):
        controls.update({"ground_rock_alternate.png": (90, 95, 80),
                         "ground_grass.png": (50, 100, 30), "ground_dry_grass.png": (110, 90, 45)})
    records = []
    reference_root = fixture / "assets/user_reference"
    for filename, color in controls.items():
        path = fixture / "assets/user_reference" / filename
        path.parent.mkdir(parents=True, exist_ok=True)
        payload = generated_png(color)
        path.write_bytes(payload)
        records.append({"path": filename, "sha256": hashlib.sha256(payload).hexdigest(), "bytes": len(payload)})
    if records:
        # The production loader verifies the private manifest before loading
        # media. Generated controls must satisfy that same contract, otherwise
        # every positive/mutation case silently becomes asset-absent coverage.
        (reference_root / "manifest.json").write_text(json.dumps({"format_version": 1, "files": records}))
    if case == "tampered-alternate":
        (reference_root / "ground_rock_alternate.png").write_bytes(generated_png((200, 20, 20)))
    env = os.environ.copy()
    env.update(YARDMAN_ROLE_CASE=case, GODOT_SILENCE_ROOT_WARNING="1", XDG_DATA_HOME=str(root / "user-data"))
    command = [executable, "--headless", "--path", str(fixture)]
    import_code, import_log = engine(command + ["--editor", "--quit"], env, timeout)
    imported = import_code == 0 and not ERRORS.search(import_log)
    code, log = engine(command + ["--script", "res://fixture.gd"], env, timeout) if imported else (125, "Import failed\n")
    marker = f"YARDMAN_REFERENCE_ROLE_CASE PASS case={case}"
    passed = bool(imported and code == 0 and marker in log and not ERRORS.search(log))
    if mutation:
        passed = bool(imported and code not in (0, 124, 125)
                      and "REFERENCE_ROLE: rejected original loaded instead of procedural rock" in log
                      and "SCRIPT ERROR" not in log and "Parse Error" not in log and marker not in log)
    if evidence:
        (evidence / f"{name}-import.log").write_text(import_log)
        (evidence / f"{name}.log").write_text(log)
    return {"case": name, "passed": passed, "import_exit": import_code,
            "run_exit": code, "expected_failure": mutation, "generated_controls": sorted(controls)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True, help="Godot 4.7.2 executable or command")
    parser.add_argument("--project-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--evidence-dir", type=Path)
    parser.add_argument("--mutation-control", action="store_true")
    parser.add_argument("--timeout", type=float, default=45, help="Seconds per Godot invocation")
    args = parser.parse_args()
    project = args.project_root.resolve()
    if not (project / "project.godot").is_file():
        project /= "godot"
    if not (project / "project.godot").is_file():
        parser.error("--project-root must contain project.godot or godot/project.godot")
    executable = shutil.which(args.godot)
    if not executable or args.timeout <= 0:
        parser.error("Godot executable and positive timeout required")
    evidence = args.evidence_dir.resolve() if args.evidence_dir else None
    if evidence and evidence.is_relative_to((project / "assets/user_reference").resolve()):
        parser.error("Evidence must not write into the owner's reference directory")
    if evidence:
        evidence.mkdir(parents=True, exist_ok=True)
    report = {"scope": "Host headless loader/material logic; no render or Android acceptance",
              "private_assets_used": False, "cases": []}
    try:
        code, version = engine([executable, "--version"], os.environ.copy(), args.timeout)
        if code != 0 or not version.strip().startswith("4.7.2."):
            raise ValueError("Godot 4.7.2 required: " + version.strip())
        sources = production_sources(project)
        report.update(engine=version.strip(), production_sha256={p: hashlib.sha256(b).hexdigest() for p, b in sources.items()})
        with tempfile.TemporaryDirectory(prefix="yardman-role-fixture-") as temporary:
            root = Path(temporary)
            for case in CASES:
                report["cases"].append(run_case(executable, root, sources, case, evidence, args.timeout))
            if args.mutation_control:
                report["cases"].append(run_case(executable, root, sources, "original-only", evidence, args.timeout, True))
        if any((project / p).read_bytes() != b for p, b in sources.items()):
            raise ValueError("Production source changed during validation")
        report["passed"] = all(case["passed"] for case in report["cases"])
    except (OSError, ValueError) as error:
        report.update(passed=False, error=str(error))
    if evidence:
        (evidence / "reference-role-fallback-report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    print("YARDMAN_REFERENCE_ROLE_FALLBACK_VALIDATOR " + ("PASS" if report["passed"] else "FAIL"))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
