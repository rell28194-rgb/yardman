#!/usr/bin/env python3
"""Build the next Yardman RR3 random-access recovery queue.

Consumes the completed Beta1+Car Parking+RR3 crossmatch and a validated RR3
recovery checkpoint. Already recovered RR3 directories are removed, explicit
no-match results are preserved, and exact motorsport variants remain eligible
as player-only private-garage vehicles while staying excluded from AI traffic.
"""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any

MOTORSPORT_RE = re.compile(
    r"(?:_dtm|_gt3|_gt4|_lms|_cup|_gte|_gt2|_race|_racing)(?:_|$)", re.I
)
PORSCHE_RE = re.compile(r"\bporsche\b", re.I)


def load(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def recovered_ids(recovery: dict[str, Any]) -> set[str]:
    out: set[str] = set()
    previous = recovery.get("previous_validated_batch") or {}
    for value in previous.get("vehicles", []) or []:
        if value:
            out.add(str(value))

    for key in ("new_validated_batch", "validated_batch"):
        block = recovery.get(key) or []
        if isinstance(block, dict):
            block = block.get("vehicles", []) or []
        for row in block:
            if isinstance(row, str):
                out.add(row)
            elif isinstance(row, dict):
                value = row.get("rr3_vehicle") or row.get("vehicle")
                if value:
                    out.add(str(value))
    return out


def score(source_id: str, status: str) -> tuple[int, str, str]:
    if MOTORSPORT_RE.search(source_id):
        return 75, "player_only_vehicle_candidate_and_component_reference", "owner_private_player_only"
    if "strong_" in status or "exact_" in status:
        return 100, "body_and_component_candidate", "normal_vehicle_candidate"
    if "generation" in status or "trim" in status:
        return 80, "generation_gate_body_candidate", "normal_vehicle_candidate"
    return 60, "component_candidate", "normal_vehicle_candidate"


def build(fusion: dict[str, Any], recovery: dict[str, Any]) -> dict[str, Any]:
    recovered = recovered_ids(recovery)
    queue: list[dict[str, Any]] = []
    no_match: list[dict[str, Any]] = []

    for row in fusion.get("candidates", []) or []:
        identity = str(row.get("beta1") or "").strip()
        status = str(row.get("rr3_status") or "")
        matches = [str(value) for value in (row.get("rr3_matches") or []) if value]

        if not matches:
            no_match.append(
                {
                    "identity": identity,
                    "rr3_status": status,
                    "note": row.get("note"),
                }
            )
            continue

        for source_id in matches:
            if source_id in recovered:
                continue
            # Current Yardman vehicle-production policy excludes Porsche. Do not
            # allow stale historical rights overlays to add one to a recovery queue.
            if PORSCHE_RE.search(identity) or PORSCHE_RE.search(source_id):
                continue
            priority, intended_use, availability_class = score(source_id, status)
            motorsport = availability_class == "owner_private_player_only"
            queue.append(
                {
                    "identity": identity,
                    "rr3_vehicle": source_id,
                    "priority": priority,
                    "intended_use": intended_use,
                    "availability_class": availability_class,
                    "player_selectable": True,
                    "ai_driver_eligible": not motorsport,
                    "ambient_spawn_eligible": not motorsport,
                    "crossmatch_status": status,
                    "promotion_gate": (
                        "exact motorsport variant may ship as its own player-only vehicle after the normal quality/physics gate; "
                        "it must not substitute for the road body and must not enter AI/ambient pools"
                        if motorsport
                        else "exact model/generation/trim compatibility required; later-generation shells must not substitute for road bodies"
                    ),
                }
            )

    queue.sort(
        key=lambda row: (
            -int(row["priority"]),
            str(row["identity"]).casefold(),
            str(row["rr3_vehicle"]).casefold(),
        )
    )

    return {
        "format_version": 2,
        "checkpoint": "rr3-recovery-queue-004",
        "source": fusion.get("checkpoint", "rr3-crossmatch"),
        "recovery_source": recovery.get("checkpoint", "rr3-recovery"),
        "policy": {
            "porsche": "excluded",
            "crown007": "accepted/deprioritized; shared improvements only",
            "private_media_public_git": False,
            "quality": (
                "high-detail LOD0; optimize via LOD/runtime, not hero-vehicle degradation"
            ),
            "quantity": (
                "no artificial fleet cap; keep every distinct validated vehicle that passes the same quality gate"
            ),
            "motorsport_variants": (
                "player-only private-garage candidates; excluded from AI and ambient traffic"
            ),
        },
        "already_recovered_rr3_vehicle_directories": sorted(recovered),
        "queue": queue,
        "verified_no_match_identities": no_match,
        "summary": {
            "already_recovered": len(recovered),
            "queued": len(queue),
            "normal_vehicle_candidates": sum(
                1
                for row in queue
                if row["availability_class"] == "normal_vehicle_candidate"
            ),
            "player_only_motorsport_vehicle_candidates": sum(
                1
                for row in queue
                if row["availability_class"] == "owner_private_player_only"
            ),
            "verified_no_match_identities": len(no_match),
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("fusion", type=Path)
    parser.add_argument("recovery", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    result = build(load(args.fusion), load(args.recovery))
    text = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding="utf-8")
    print(text, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
