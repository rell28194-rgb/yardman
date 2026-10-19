#!/usr/bin/env python3
"""Mutation-grade Yardman's conservative HZB correctness oracles.

Only syntax-valid semantic faults are injected. The immutable Godot tests decide
whether a mutant is killed; this tool never changes the success criteria.
"""

from __future__ import annotations

import argparse
import subprocess
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Mutant:
    name: str
    path: str
    needle: str
    replacement: str
    scripts: tuple[str, ...]


MUTANTS = (
    Mutant(
        "reduce_max_to_min",
        "shaders/gpu_hzb_reduce.glsl",
        "maximum_depth = max(maximum_depth, pyramid.depth[src_offset + y * src_width + x]);",
        "maximum_depth = min(maximum_depth, pyramid.depth[src_offset + y * src_width + x]);",
        ("res://tests/gpu_hzb_test.gd",),
    ),
    Mutant(
        "reduce_x_stride_one",
        "shaders/gpu_hzb_reduce.glsl",
        "uint src_x = dst_x * 2u;",
        "uint src_x = dst_x * 1u;",
        ("res://tests/gpu_hzb_test.gd",),
    ),
    Mutant(
        "reduce_y_stride_one",
        "shaders/gpu_hzb_reduce.glsl",
        "uint src_y = dst_y * 2u;",
        "uint src_y = dst_y * 1u;",
        ("res://tests/gpu_hzb_test.gd",),
    ),
    Mutant(
        "cull_max_to_min",
        "shaders/gpu_hzb_cull.glsl",
        "maximum_depth = max(maximum_depth,\n                pyramid.depth[chosen.x + y * chosen.y + x]);",
        "maximum_depth = min(maximum_depth,\n                pyramid.depth[chosen.x + y * chosen.y + x]);",
        ("res://tests/gpu_hzb_test.gd",),
    ),
    Mutant(
        "cull_invert_depth_test",
        "shaders/gpu_hzb_cull.glsl",
        "bool definitely_occluded = maximum_depth + DEPTH_BIAS_M < near_depth;",
        "bool definitely_occluded = maximum_depth + DEPTH_BIAS_M > near_depth;",
        ("res://tests/gpu_hzb_test.gd",),
    ),
    Mutant(
        "cull_remove_bias",
        "shaders/gpu_hzb_cull.glsl",
        "bool definitely_occluded = maximum_depth + DEPTH_BIAS_M < near_depth;",
        "bool definitely_occluded = maximum_depth < near_depth;",
        ("res://tests/gpu_hzb_test.gd",),
    ),
    Mutant(
        "cull_negative_bias",
        "shaders/gpu_hzb_cull.glsl",
        "bool definitely_occluded = maximum_depth + DEPTH_BIAS_M < near_depth;",
        "bool definitely_occluded = maximum_depth - DEPTH_BIAS_M < near_depth;",
        ("res://tests/gpu_hzb_test.gd",),
    ),
    Mutant(
        "cull_invert_visibility",
        "shaders/gpu_hzb_cull.glsl",
        "output_flags.visible[index] = definitely_occluded ? 0u : 1u;",
        "output_flags.visible[index] = definitely_occluded ? 1u : 0u;",
        ("res://tests/gpu_hzb_test.gd",),
    ),
    Mutant(
        "roadside_remove_screen_margin",
        "scripts/gpu_roadside_hzb_probe.gd",
        "const SCREEN_MARGIN_PIXELS := 1.5",
        "const SCREEN_MARGIN_PIXELS := 0.0",
        ("res://tests/gpu_roadside_hzb_test.gd",),
    ),
    Mutant(
        "roadside_use_far_sphere_depth",
        "scripts/gpu_roadside_hzb_probe.gd",
        "var nearest_depth := depth - radius",
        "var nearest_depth := depth + radius",
        ("res://tests/gpu_roadside_hzb_test.gd",),
    ),
    Mutant(
        "roadside_shrink_projection_radius",
        "scripts/gpu_roadside_hzb_probe.gd",
        "var radius := maxf(0.25, scale * 2.0)",
        "var radius := maxf(0.25, scale * 0.5)",
        ("res://tests/gpu_roadside_hzb_test.gd",),
    ),
    Mutant(
        "depth_linearization_sign",
        "shaders/gpu_depth_capture.glsl",
        "linear_depth = max(0.0, -view.z / view.w);",
        "linear_depth = max(0.0, view.z / view.w);",
        ("res://tests/gpu_real_depth_test.gd",),
    ),
    Mutant(
        "depth_flip_reverse_z_sample",
        "shaders/gpu_depth_capture.glsl",
        "float raw_depth = texture(depth_texture, uv).r;",
        "float raw_depth = 1.0 - texture(depth_texture, uv).r;",
        ("res://tests/gpu_real_depth_test.gd",),
    ),
    Mutant(
        "depth_wrong_ndc_xy",
        "shaders/gpu_depth_capture.glsl",
        "vec3 ndc = vec3(uv * 2.0 - 1.0, raw_depth);",
        "vec3 ndc = vec3(uv * 2.0 + 1.0, raw_depth);",
        ("res://tests/gpu_real_depth_test.gd",),
    ),
)

MARKERS = {
    "res://tests/gpu_hzb_test.gd": "YARDMAN_GPU_HZB_TEST PASS",
    "res://tests/gpu_real_depth_test.gd": "YARDMAN_GPU_REAL_DEPTH_TEST PASS",
    "res://tests/gpu_roadside_hzb_test.gd": "YARDMAN_GPU_ROADSIDE_HZB_TEST PASS",
}


def godot_prefix(godot: str, root: Path) -> list[str]:
    return [
        "xvfb-run", "-a", "-s", "-screen 0 1280x720x24",
        godot, "--path", str(root), "--rendering-method", "mobile",
        "--rendering-driver", "vulkan", "--audio-driver", "Dummy",
    ]


def refresh_shader_imports(godot: str, root: Path, timeout: int) -> tuple[bool, str]:
    proc = subprocess.run(
        godot_prefix(godot, root) + ["--editor", "--quit"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=timeout,
        check=False,
    )
    bad = ("Parse Error", "SCRIPT ERROR", "Shader compilation failed", "Failed to compile shader")
    return proc.returncode == 0 and not any(token in proc.stdout for token in bad), proc.stdout


def run_oracle(godot: str, root: Path, script: str, timeout: int) -> tuple[bool, str]:
    proc = subprocess.run(
        godot_prefix(godot, root) + ["--script", script],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=timeout,
        check=False,
    )
    marker = MARKERS[script]
    return proc.returncode == 0 and marker in proc.stdout, proc.stdout


def run_set(godot: str, root: Path, scripts: tuple[str, ...], timeout: int) -> tuple[bool, str]:
    outputs: list[str] = []
    for script in scripts:
        passed, output = run_oracle(godot, root, script, timeout)
        outputs.append(output)
        if not passed:
            return False, "\n".join(outputs)
    return True, "\n".join(outputs)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot-binary", default="godot")
    parser.add_argument("--threshold", type=float, default=0.90)
    parser.add_argument("--timeout", type=int, default=45)
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[1]
    baseline_scripts = tuple(MARKERS)
    baseline_ok, baseline_output = run_set(args.godot_binary, root, baseline_scripts, args.timeout)
    if not baseline_ok:
        print("BASELINE_FAILED", flush=True)
        print(baseline_output, flush=True)
        return 2

    paths = {mutant.path for mutant in MUTANTS}
    originals = {path: (root / path).read_text(encoding="utf-8") for path in paths}
    killed = 0
    survived = 0
    invalid = 0
    survivors: list[str] = []
    invalid_names: list[str] = []

    try:
        for mutant in MUTANTS:
            target = root / mutant.path
            original = originals[mutant.path]
            if mutant.needle not in original:
                invalid += 1
                invalid_names.append(mutant.name)
                print(f"MUTANT_INVALID name={mutant.name} reason=needle_missing", flush=True)
                continue

            target.write_text(original.replace(mutant.needle, mutant.replacement, 1), encoding="utf-8")
            import_ok = True
            if target.suffix == ".glsl":
                import_ok, _ = refresh_shader_imports(args.godot_binary, root, args.timeout)
            passed = False
            if import_ok:
                passed, _ = run_set(args.godot_binary, root, mutant.scripts, args.timeout)

            target.write_text(original, encoding="utf-8")
            if target.suffix == ".glsl":
                restored, restore_output = refresh_shader_imports(args.godot_binary, root, args.timeout)
                if not restored:
                    print("BASELINE_RESTORE_FAILED", flush=True)
                    print(restore_output, flush=True)
                    return 3

            if passed:
                survived += 1
                survivors.append(mutant.name)
                print(f"MUTANT_SURVIVED name={mutant.name}", flush=True)
            else:
                killed += 1
                print(f"MUTANT_KILLED name={mutant.name}", flush=True)
    finally:
        for path, original in originals.items():
            (root / path).write_text(original, encoding="utf-8")

    valid = killed + survived
    score = float(killed) / float(valid) if valid else 0.0
    print(
        "YARDMAN_RDX_HZB_MUTATION "
        f"score={score:.4f} killed={killed} valid={valid} survivors={survived} "
        f"invalid={invalid} threshold={args.threshold:.4f}",
        flush=True,
    )
    if survivors:
        print("SURVIVORS " + ",".join(survivors), flush=True)
    if invalid_names:
        print("INVALID " + ",".join(invalid_names), flush=True)
    return 0 if valid > 0 and invalid == 0 and score >= args.threshold else 1


if __name__ == "__main__":
    raise SystemExit(main())
