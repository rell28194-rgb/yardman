#!/usr/bin/env python3
"""Resolve Car Parking Multiplayer vehicle identities from exact UnityFS bundle evidence.

The input probe is metadata extracted from the actual current car<ID> Addressables
bundles. Global Addressables catalog names are secondary evidence only because the
catalog can contain imported/reused directories for unrelated cars.

No media is read by this resolver. It consumes metadata JSON and emits metadata JSON.
Porsche-family identities are excluded. Conflicts remain unresolved instead of being
silently relabeled.
"""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any

PORSCHE_RE = re.compile(
    r"(?:porsche|porsch|panamer|cayenne|carrera\s*gt|919\s*hybrid|918\s*spyder|"
    r"\b911\b|gt3\s*rs)",
    re.I,
)

SPECIAL = {
    21: {
        "identity": None,
        "status": "conflict_catalog_vs_exact_bundle",
        "note": "Catalog says Jeep Grand Cherokee SRT-8; exact car21 bundle carries Wrangler materials/audio. Keep unresolved until dependency/visual identity is proved.",
    },
    37: {
        "identity": "Ford Transit SuperSportVan",
        "status": "resolved_catalog_plus_exact_bundle_audio",
        "note": "Exact bundle audio is 37_101_Ford_Transite; catalog model directory is 37 Ford Transit SuperSportVan.",
    },
    101: {
        "identity": "Ford Transit",
        "status": "resolved_shared_family_variant",
        "note": "Exact car101 bundle reuses 37 Ford Transit SuperSportVan model directory and shared 37_101 Ford Transit audio.",
    },
    122: {
        "identity": None,
        "status": "unresolved_sell_model_only",
        "note": "Exact car122 bundle contains sell-model/wheel data but no defensible make/model identity.",
    },
    161: {
        "identity": "Jeep Grand Cherokee",
        "status": "resolved_exact_bundle_audio_family",
        "note": "Exact bundle contains 161Jeep14 family directory and Rev_161_Jeep_Grand_Cherokee_V3 audio.",
    },
    173: {
        "identity": "Mercedes CLS63 2012",
        "status": "resolved_exact_bundle_audio_family",
        "note": "Exact bundle contains 173Cls2012 family directory and 173_Mercedes_CLS63_v4 audio.",
    },
    251: {
        "identity": "Toyota Altezza",
        "status": "resolved_exact_bundle_audio_family",
        "note": "Grouped 251-255 source directory is split by exact bundle audio: 251_toyota_altezza_v4.",
    },
    255: {
        "identity": "Lexus IS300",
        "status": "resolved_exact_bundle_audio_family",
        "note": "Grouped 251-255 source directory is split by exact bundle audio/badges: 255_lexus_is300.",
    },
}


def clean_local_identity(catalog_id: int, source_dir: str) -> str:
    value = source_dir.strip()
    value = re.sub(rf"^{catalog_id}(?:[\s_-]+)?", "", value, count=1, flags=re.I)
    return re.sub(r"_+", " ", value).strip()


def catalog_candidates(catalog_decode: dict[str, Any], catalog_id: int) -> list[str]:
    return sorted({
        str(r.get("identity", "")).strip()
        for r in catalog_decode.get("exact", [])
        if r.get("catalog_id") == catalog_id and str(r.get("identity", "")).strip()
    }, key=str.casefold)


def resolve(probe: dict[str, Any], catalog_decode: dict[str, Any] | None = None) -> dict[str, Any]:
    catalog_decode = catalog_decode or {}
    out: list[dict[str, Any]] = []
    for vehicle in sorted(probe.get("vehicles", []), key=lambda x: int(x["catalog_id"])):
        cid = int(vehicle["catalog_id"])
        local_dirs = list(vehicle.get("matching_model_directories", []) or [])
        all_dirs = list(vehicle.get("all_model_directories", []) or [])
        audio = list(vehicle.get("audio_event_candidates", []) or [])
        cats = catalog_candidates(catalog_decode, cid)

        identity: str | None = None
        status = "unresolved"
        note = None

        if cid in SPECIAL:
            identity = SPECIAL[cid]["identity"]
            status = SPECIAL[cid]["status"]
            note = SPECIAL[cid]["note"]
        elif len(local_dirs) == 1 and "-" not in local_dirs[0].split(" ", 1)[0]:
            identity = clean_local_identity(cid, local_dirs[0])
            status = "resolved_from_exact_bundle_model_directory"
        elif len(local_dirs) > 1:
            status = "conflict_multiple_exact_bundle_model_directories"
            note = "Multiple same-ID model directories occur in the exact bundle."
        elif len(cats) == 1 and any(str(cid) in x for x in all_dirs):
            identity = cats[0]
            status = "resolved_catalog_plus_bundle_family_evidence"
        else:
            status = "unresolved_no_exact_bundle_identity"

        evidence_text = " ".join(([identity] if identity else []) + local_dirs + all_dirs + audio + cats)
        rights = "excluded_porsche" if PORSCHE_RE.search(evidence_text) else (
            "owner_authorized_non_porsche" if identity else "identity_gate_required"
        )
        if rights == "excluded_porsche":
            status = "excluded_porsche"

        out.append({
            "catalog_id": cid,
            "identity": identity,
            "identity_status": status,
            "rights_status": rights,
            "bundle_path": vehicle.get("bundle_path"),
            "bundle_bytes": vehicle.get("bundle_bytes"),
            "unity_revision": vehicle.get("unity_revision"),
            "exact_bundle_model_directories": local_dirs,
            "bundle_family_directories": all_dirs[:12],
            "bundle_audio_evidence": audio[:12],
            "catalog_identity_candidates": cats,
            **({"note": note} if note else {}),
        })

    counts = {
        "current_car_bundles": len(out),
        "resolved_non_porsche": sum(1 for r in out if r["identity"] and r["rights_status"] == "owner_authorized_non_porsche"),
        "excluded_porsche": sum(1 for r in out if r["rights_status"] == "excluded_porsche"),
        "conflict_review_required": sum(1 for r in out if r["identity_status"].startswith("conflict_")),
        "unresolved": sum(1 for r in out if r["identity"] is None and not r["identity_status"].startswith("conflict_")),
        "unityfs_parse_errors": int(probe.get("counts", {}).get("parse_errors", 0)),
    }
    return {
        "format_version": 1,
        "source": "Car Parking Multiplayer 4.9.11 exact current Addressables car bundles",
        "policy": {
            "exact_bundle_over_global_catalog": True,
            "do_not_guess_conflicts": True,
            "porsche": "excluded",
            "media": "metadata only; no recovered vehicle media embedded",
        },
        "counts": counts,
        "vehicles": out,
    }


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("bundle_probe", type=Path)
    p.add_argument("--catalog-decode", type=Path)
    p.add_argument("--output", type=Path)
    args = p.parse_args()
    probe = json.loads(args.bundle_probe.read_text(encoding="utf-8"))
    catalog = json.loads(args.catalog_decode.read_text(encoding="utf-8")) if args.catalog_decode else None
    result = resolve(probe, catalog)
    text = json.dumps(result, indent=2, ensure_ascii=False, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding="utf-8")
    print(text, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
