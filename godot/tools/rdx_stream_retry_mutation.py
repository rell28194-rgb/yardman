#!/usr/bin/env python3
"""Curated semantic mutation gate for Yardman's streaming recovery stack.

The LLM/research lane may propose scenarios and implementation candidates, but
this runner owns the verifier. Every mutant is intended to stay syntax-valid and
represent a realistic policy or orchestration regression. Mutants are only
credited when the unchanged Godot adversarial oracle rejects them.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path

PASS_MARKER = "YARDMAN_STREAMING_ADVERSARIAL_TEST PASS"
PARSE_MARKERS = ("SCRIPT ERROR", "Parse Error", "Parser Error")
POLICY = "stream_retry_policy.gd"
RUNTIME = "stream_recovery_runtime.gd"

MUTANTS = [
    {"file": POLICY, "name": "backoff_off_by_one", "target": "var exponent := clampi(attempts - 1, 0, 10)", "replacement": "var exponent := clampi(attempts, 0, 10)"},
    {"file": POLICY, "name": "backoff_disabled", "target": "return mini(RETRY_MAX_MS, RETRY_BASE_MS * (1 << exponent))", "replacement": "return RETRY_BASE_MS"},
    {"file": POLICY, "name": "retry_cap_reduced", "target": "const RETRY_MAX_MS := 30000", "replacement": "const RETRY_MAX_MS := 15000"},
    {"file": POLICY, "name": "attempt_counter_does_not_increment", "target": "var next_attempt := int(attempts.get(key, 0)) + 1", "replacement": "var next_attempt := int(attempts.get(key, 0)) + 0"},
    {"file": POLICY, "name": "retry_deadline_immediate", "target": '"retry_at_msec": now + retry_delay_ms(next_attempt),', "replacement": '"retry_at_msec": now,'},
    {"file": POLICY, "name": "failure_category_discarded", "target": '"category": category,', "replacement": '"category": "stream",'},
    {"file": POLICY, "name": "loaded_attempt_history_not_cleared", "target": "        attempts.erase(key)\n        if failed.erase(key):", "replacement": "        if false:\n            attempts.erase(key)\n        if failed.erase(key):"},
    {"file": POLICY, "name": "loaded_failure_not_removed", "target": "        if failed.erase(key):\n            loaded_cleared += 1", "replacement": "        if failed.has(key):\n            loaded_cleared += 1"},
    {"file": POLICY, "name": "loaded_cleanup_metric_lost", "target": 'stats["loaded_failures_cleared"] = int(stats.get("loaded_failures_cleared", 0)) + loaded_cleared', "replacement": 'stats["loaded_failures_cleared"] = int(stats.get("loaded_failures_cleared", 0)) + 0'},
    {"file": POLICY, "name": "deadline_excludes_exact_boundary", "target": 'if now >= int((state as Dictionary).get("retry_at_msec", now)):', "replacement": 'if now > int((state as Dictionary).get("retry_at_msec", now)):'},
    {"file": POLICY, "name": "due_failure_not_removed", "target": "        if now >= int((state as Dictionary).get(\"retry_at_msec\", now)):\n            failed.erase(key_value)\n            released += 1", "replacement": "        if now >= int((state as Dictionary).get(\"retry_at_msec\", now)):\n            released += 1"},
    {"file": POLICY, "name": "retry_release_metric_lost", "target": 'stats["retries_released"] = int(stats.get("retries_released", 0)) + released', "replacement": 'stats["retries_released"] = int(stats.get("retries_released", 0)) + 0'},
    {"file": POLICY, "name": "stale_failure_cleanup_inverted", "target": "        if wanted.has(key):\n            continue\n        failed.erase(key_value)\n        attempts.erase(key)\n        dropped += 1", "replacement": "        if not wanted.has(key):\n            continue\n        failed.erase(key_value)\n        attempts.erase(key)\n        dropped += 1"},
    {"file": POLICY, "name": "stale_failure_metric_lost", "target": 'stats["stale_failures_dropped"] = int(stats.get("stale_failures_dropped", 0)) + dropped', "replacement": 'stats["stale_failures_dropped"] = int(stats.get("stale_failures_dropped", 0)) + 0'},
    {"file": POLICY, "name": "orphan_attempt_cleanup_inverted", "target": "        if wanted.has(key):\n            continue\n        attempts.erase(key_value)\n        orphan_attempts_dropped += 1", "replacement": "        if not wanted.has(key):\n            continue\n        attempts.erase(key_value)\n        orphan_attempts_dropped += 1"},
    {"file": POLICY, "name": "orphan_attempt_metric_lost", "target": 'stats["stale_attempts_dropped"] = int(stats.get("stale_attempts_dropped", 0)) + orphan_attempts_dropped', "replacement": 'stats["stale_attempts_dropped"] = int(stats.get("stale_attempts_dropped", 0)) + 0'},
    {"file": POLICY, "name": "active_failure_accounting_zeroed", "target": '    stats["failures_recorded"] = int(stats.get("failures_recorded", 0)) + 1\n    stats["active_failures"] = failed.size()', "replacement": '    stats["failures_recorded"] = int(stats.get("failures_recorded", 0)) + 1\n    stats["active_failures"] = 0'},
    {"file": POLICY, "name": "legacy_retry_releases_too_early", "target": 'record_failure(failed, attempts, str(key_value), stats, "legacy", now)', "replacement": 'record_failure(failed, attempts, str(key_value), stats, "legacy", now - RETRY_BASE_MS)'},
    {"file": RUNTIME, "name": "owner_key_collapses_streamers", "target": 'return "%s:%d" % [label, streamer.get_instance_id()]', "replacement": "return label"},
    {"file": RUNTIME, "name": "runtime_skips_stale_cleanup", "target": "    RetryPolicy.forget_unwanted(failed, attempts, wanted, stats)", "replacement": "    if false:\n        RetryPolicy.forget_unwanted(failed, attempts, wanted, stats)"},
    {"file": RUNTIME, "name": "runtime_skips_retry_service", "target": "    var released := RetryPolicy.release_due(failed, attempts, loaded, stats, now_msec)", "replacement": "    var released := 0"},
    {"file": RUNTIME, "name": "runtime_refreshes_without_release", "target": '    if released > 0 and streamer.has_method("update_world"):', "replacement": '    if released >= 0 and streamer.has_method("update_world"):'},
    {"file": RUNTIME, "name": "runtime_swaps_world_coordinates", "target": '            streamer.call("update_world", world.x, world.y, true)', "replacement": '            streamer.call("update_world", world.y, world.x, true)'},
    {"file": RUNTIME, "name": "runtime_loses_force_refresh_flag", "target": '            streamer.call("update_world", world.x, world.y, true)', "replacement": '            streamer.call("update_world", world.x, world.y, false)'},
    {"file": RUNTIME, "name": "runtime_refresh_metric_lost", "target": '            stats["forced_refreshes"] = int(stats.get("forced_refreshes", 0)) + 1', "replacement": '            stats["forced_refreshes"] = int(stats.get("forced_refreshes", 0)) + 0'},
]


def run_oracle(binary: str, godot_dir: Path, timeout_seconds: int) -> tuple[int, str]:
    proc = subprocess.run(
        [binary, "--headless", "--path", str(godot_dir), "--script", "res://tests/streaming_adversarial_test.gd"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=timeout_seconds,
        check=False,
    )
    return proc.returncode, proc.stdout


def apply_mutant(source: str, mutant: dict[str, str]) -> str:
    target = mutant["target"]
    count = source.count(target)
    if count != 1:
        raise RuntimeError(f"mutant {mutant['name']} expected exactly one target occurrence, found {count}")
    return source.replace(target, mutant["replacement"], 1)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot-binary", default="godot")
    parser.add_argument("--threshold", type=float, default=1.0)
    parser.add_argument("--timeout", type=int, default=30)
    args = parser.parse_args()

    if not 0.0 <= args.threshold <= 1.0:
        raise SystemExit("--threshold must be between 0 and 1")

    godot_dir = Path(__file__).resolve().parents[1]
    script_dir = godot_dir / "scripts"
    paths = {name: script_dir / name for name in {str(mutant["file"]) for mutant in MUTANTS}}
    originals = {name: path.read_text(encoding="utf-8") for name, path in paths.items()}
    source_hashes = {name: hashlib.sha256(source.encode("utf-8")).hexdigest() for name, source in originals.items()}

    build_dir = godot_dir / "build"
    build_dir.mkdir(parents=True, exist_ok=True)
    report_path = build_dir / "rdx-stream-recovery-mutation.json"

    baseline_code, baseline_output = run_oracle(args.godot_binary, godot_dir, args.timeout)
    if baseline_code != 0 or PASS_MARKER not in baseline_output:
        print("RDX_MUTATION baseline adversarial oracle is not green", file=sys.stderr)
        print(baseline_output[-4000:], file=sys.stderr)
        return 2

    results: list[dict[str, object]] = []
    try:
        for mutant in MUTANTS:
            filename = str(mutant["file"])
            target_path = paths[filename]
            mutated = apply_mutant(originals[filename], mutant)
            target_path.write_text(mutated, encoding="utf-8")
            code, output = run_oracle(args.godot_binary, godot_dir, args.timeout)
            parse_dirty = any(marker in output for marker in PARSE_MARKERS)
            killed = code != 0 or PASS_MARKER not in output
            results.append(
                {
                    "file": filename,
                    "name": mutant["name"],
                    "killed": killed,
                    "parse_dirty": parse_dirty,
                    "return_code": code,
                    "pass_marker": PASS_MARKER in output,
                    "tail": output[-1200:],
                }
            )
            state = "KILLED" if killed else "SURVIVED"
            print(f"RDX_MUTATION {state} {filename}:{mutant['name']} code={code} parse_dirty={int(parse_dirty)}")
            target_path.write_text(originals[filename], encoding="utf-8")
    finally:
        for filename, path in paths.items():
            path.write_text(originals[filename], encoding="utf-8")

    invalid = [result for result in results if bool(result["parse_dirty"])]
    valid = [result for result in results if not bool(result["parse_dirty"])]
    killed = [result for result in valid if bool(result["killed"])]
    survivors = [result for result in valid if not bool(result["killed"])]
    score = (len(killed) / len(valid)) if valid else 0.0

    report = {
        "schema_version": 2,
        "source_sha256": source_hashes,
        "mutants_total": len(results),
        "mutants_valid": len(valid),
        "mutants_invalid": len(invalid),
        "mutants_killed": len(killed),
        "mutants_survived": len(survivors),
        "mutation_score": score,
        "required_score": args.threshold,
        "survivors": [f"{result['file']}:{result['name']}" for result in survivors],
        "invalid_mutants": [f"{result['file']}:{result['name']}" for result in invalid],
        "results": results,
    }
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    print(
        "YARDMAN_RDX_MUTATION_SCORE "
        f"score={score:.4f} killed={len(killed)} valid={len(valid)} "
        f"survivors={len(survivors)} invalid={len(invalid)} threshold={args.threshold:.4f}"
    )

    if invalid:
        print("RDX_MUTATION invalid semantic mutants: " + ", ".join(f"{x['file']}:{x['name']}" for x in invalid), file=sys.stderr)
        return 3
    if survivors or score < args.threshold:
        print("RDX_MUTATION surviving mutants: " + ", ".join(f"{x['file']}:{x['name']}" for x in survivors), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
