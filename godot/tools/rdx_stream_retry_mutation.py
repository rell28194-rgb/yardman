#!/usr/bin/env python3
"""Curated semantic mutation gate for Yardman's streaming retry policy.

The LLM/research lane is allowed to propose tests and candidates, but this runner
keeps the verifier deterministic. Each mutant is intentionally syntax-valid and
represents a realistic retry/recovery regression. A mutant is killed only when
the normal Godot adversarial oracle rejects it.
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

MUTANTS = [
    {
        "name": "backoff_off_by_one",
        "target": "var exponent := clampi(attempts - 1, 0, 10)",
        "replacement": "var exponent := clampi(attempts, 0, 10)",
    },
    {
        "name": "backoff_disabled",
        "target": "return mini(RETRY_MAX_MS, RETRY_BASE_MS * (1 << exponent))",
        "replacement": "return RETRY_BASE_MS",
    },
    {
        "name": "retry_cap_reduced",
        "target": "const RETRY_MAX_MS := 30000",
        "replacement": "const RETRY_MAX_MS := 15000",
    },
    {
        "name": "attempt_counter_does_not_increment",
        "target": "var next_attempt := int(attempts.get(key, 0)) + 1",
        "replacement": "var next_attempt := int(attempts.get(key, 0)) + 0",
    },
    {
        "name": "retry_deadline_immediate",
        "target": '"retry_at_msec": now + retry_delay_ms(next_attempt),',
        "replacement": '"retry_at_msec": now,',
    },
    {
        "name": "failure_category_discarded",
        "target": '"category": category,',
        "replacement": '"category": "stream",',
    },
    {
        "name": "loaded_attempt_history_not_cleared",
        "target": "        attempts.erase(key)\n        if failed.erase(key):",
        "replacement": "        if false:\n            attempts.erase(key)\n        if failed.erase(key):",
    },
    {
        "name": "loaded_failure_not_removed",
        "target": "        if failed.erase(key):\n            loaded_cleared += 1",
        "replacement": "        if failed.has(key):\n            loaded_cleared += 1",
    },
    {
        "name": "loaded_cleanup_metric_lost",
        "target": 'stats["loaded_failures_cleared"] = int(stats.get("loaded_failures_cleared", 0)) + loaded_cleared',
        "replacement": 'stats["loaded_failures_cleared"] = int(stats.get("loaded_failures_cleared", 0)) + 0',
    },
    {
        "name": "deadline_excludes_exact_boundary",
        "target": 'if now >= int((state as Dictionary).get("retry_at_msec", now)):',
        "replacement": 'if now > int((state as Dictionary).get("retry_at_msec", now)):',
    },
    {
        "name": "due_failure_not_removed",
        "target": "        if now >= int((state as Dictionary).get(\"retry_at_msec\", now)):\n            failed.erase(key_value)\n            released += 1",
        "replacement": "        if now >= int((state as Dictionary).get(\"retry_at_msec\", now)):\n            released += 1",
    },
    {
        "name": "retry_release_metric_lost",
        "target": 'stats["retries_released"] = int(stats.get("retries_released", 0)) + released',
        "replacement": 'stats["retries_released"] = int(stats.get("retries_released", 0)) + 0',
    },
    {
        "name": "stale_failure_cleanup_inverted",
        "target": "        if wanted.has(key):\n            continue\n        failed.erase(key_value)\n        attempts.erase(key)\n        dropped += 1",
        "replacement": "        if not wanted.has(key):\n            continue\n        failed.erase(key_value)\n        attempts.erase(key)\n        dropped += 1",
    },
    {
        "name": "stale_failure_metric_lost",
        "target": 'stats["stale_failures_dropped"] = int(stats.get("stale_failures_dropped", 0)) + dropped',
        "replacement": 'stats["stale_failures_dropped"] = int(stats.get("stale_failures_dropped", 0)) + 0',
    },
    {
        "name": "orphan_attempt_cleanup_inverted",
        "target": "        if wanted.has(key):\n            continue\n        attempts.erase(key_value)\n        orphan_attempts_dropped += 1",
        "replacement": "        if not wanted.has(key):\n            continue\n        attempts.erase(key_value)\n        orphan_attempts_dropped += 1",
    },
    {
        "name": "orphan_attempt_metric_lost",
        "target": 'stats["stale_attempts_dropped"] = int(stats.get("stale_attempts_dropped", 0)) + orphan_attempts_dropped',
        "replacement": 'stats["stale_attempts_dropped"] = int(stats.get("stale_attempts_dropped", 0)) + 0',
    },
    {
        "name": "active_failure_accounting_zeroed",
        "target": '    stats["failures_recorded"] = int(stats.get("failures_recorded", 0)) + 1\n    stats["active_failures"] = failed.size()',
        "replacement": '    stats["failures_recorded"] = int(stats.get("failures_recorded", 0)) + 1\n    stats["active_failures"] = 0',
    },
    {
        "name": "legacy_retry_releases_too_early",
        "target": 'record_failure(failed, attempts, str(key_value), stats, "legacy", now)',
        "replacement": 'record_failure(failed, attempts, str(key_value), stats, "legacy", now - RETRY_BASE_MS)',
    },
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
        raise RuntimeError(
            f"mutant {mutant['name']} expected exactly one target occurrence, found {count}"
        )
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
    policy_path = godot_dir / "scripts" / "stream_retry_policy.gd"
    build_dir = godot_dir / "build"
    build_dir.mkdir(parents=True, exist_ok=True)
    report_path = build_dir / "rdx-stream-retry-mutation.json"

    original = policy_path.read_text(encoding="utf-8")
    original_sha256 = hashlib.sha256(original.encode("utf-8")).hexdigest()

    baseline_code, baseline_output = run_oracle(args.godot_binary, godot_dir, args.timeout)
    if baseline_code != 0 or PASS_MARKER not in baseline_output:
        print("RDX_MUTATION baseline adversarial oracle is not green", file=sys.stderr)
        print(baseline_output[-4000:], file=sys.stderr)
        return 2

    results: list[dict[str, object]] = []
    try:
        for mutant in MUTANTS:
            mutated = apply_mutant(original, mutant)
            policy_path.write_text(mutated, encoding="utf-8")
            code, output = run_oracle(args.godot_binary, godot_dir, args.timeout)
            parse_dirty = any(marker in output for marker in PARSE_MARKERS)
            killed = code != 0 or PASS_MARKER not in output
            results.append(
                {
                    "name": mutant["name"],
                    "killed": killed,
                    "parse_dirty": parse_dirty,
                    "return_code": code,
                    "pass_marker": PASS_MARKER in output,
                    "tail": output[-1200:],
                }
            )
            state = "KILLED" if killed else "SURVIVED"
            print(f"RDX_MUTATION {state} {mutant['name']} code={code} parse_dirty={int(parse_dirty)}")
            policy_path.write_text(original, encoding="utf-8")
    finally:
        policy_path.write_text(original, encoding="utf-8")

    invalid = [result for result in results if bool(result["parse_dirty"])]
    valid = [result for result in results if not bool(result["parse_dirty"])]
    killed = [result for result in valid if bool(result["killed"])]
    survivors = [result for result in valid if not bool(result["killed"])]
    score = (len(killed) / len(valid)) if valid else 0.0

    report = {
        "schema_version": 1,
        "policy_sha256": original_sha256,
        "mutants_total": len(results),
        "mutants_valid": len(valid),
        "mutants_invalid": len(invalid),
        "mutants_killed": len(killed),
        "mutants_survived": len(survivors),
        "mutation_score": score,
        "required_score": args.threshold,
        "survivors": [result["name"] for result in survivors],
        "invalid_mutants": [result["name"] for result in invalid],
        "results": results,
    }
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    print(
        "YARDMAN_RDX_MUTATION_SCORE "
        f"score={score:.4f} killed={len(killed)} valid={len(valid)} "
        f"survivors={len(survivors)} invalid={len(invalid)} threshold={args.threshold:.4f}"
    )

    if invalid:
        print("RDX_MUTATION invalid semantic mutants: " + ", ".join(str(x["name"]) for x in invalid), file=sys.stderr)
        return 3
    if survivors or score < args.threshold:
        print("RDX_MUTATION surviving mutants: " + ", ".join(str(x["name"]) for x in survivors), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
