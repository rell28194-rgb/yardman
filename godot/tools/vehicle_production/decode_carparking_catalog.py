#!/usr/bin/env python3
"""Decode Car Parking Multiplayer Addressables vehicle identities for Yardman.

Input is the recovered Addressables catalog JSON plus an optional APK inventory.
The output is identity evidence only; it never relabels another model to fill a
missing identity. Porsche-family identities are marked excluded.
"""
from __future__ import annotations

import argparse
import base64
import json
import re
from collections import defaultdict
from pathlib import Path
from typing import Any

MODEL_PATTERNS = [
    re.compile(r"Assets/_Car Parking/Art/Cars/Models/(?P<key>\d+(?:-\d+)?)\s+(?P<name>[^/]+)(?:/|$)", re.I),
    re.compile(r"Assets/_Car Parking/_Model/Cars/(?P<key>\d+(?:-\d+)?)\s+(?P<name>[^/]+)(?:/|$)", re.I),
    re.compile(r"Assets/_Model/Cars/(?P<key>\d+(?:-\d+)?)\s+(?P<name>[^/]+)(?:/|$)", re.I),
]
BUNDLE_RE = re.compile(r"assets/aa/Android/car(?P<id>\d+)_assets_all_[0-9a-f]+\.bundle", re.I)
PORSCHE_RE = re.compile(r"(?:porsche|\b911\b|\b992\b|cayman|boxster|panamera|taycan|macan)", re.I)


def strings_from_catalog(data: dict[str, Any]) -> list[str]:
    out: list[str] = []
    ids = data.get("m_InternalIds", [])
    if isinstance(ids, list):
        out.extend(str(x) for x in ids if isinstance(x, str))
    raw = data.get("m_KeyDataString")
    if isinstance(raw, str) and raw:
        try:
            decoded = base64.b64decode(raw)
            out.extend(x.decode("utf-8", "ignore") for x in re.findall(rb"[\x20-\x7e]{8,}", decoded))
        except Exception:
            pass
    return out


def bundle_map(apk_inventory: Any) -> dict[int, str]:
    text = json.dumps(apk_inventory, ensure_ascii=False)
    return {int(m.group("id")): m.group(0) for m in BUNDLE_RE.finditer(text)}


def parse_model_dirs(strings: list[str]) -> dict[str, dict[str, Any]]:
    found: dict[str, dict[str, Any]] = {}
    evidence: dict[tuple[str, str], list[str]] = defaultdict(list)
    for text in strings:
        for pattern in MODEL_PATTERNS:
            for match in pattern.finditer(text):
                key = match.group("key")
                name = " ".join(match.group("name").strip().split())
                evidence[(key, name)].append(match.group(0).rstrip("/"))
    for (key, name), paths in sorted(evidence.items(), key=lambda x: (int(x[0][0].split("-")[0]), x[0][1].casefold())):
        grouped = "-" in key
        first = int(key.split("-")[0])
        last = int(key.split("-")[-1])
        found[f"{key}:{name}"] = {
            "catalog_key": key,
            "catalog_id": None if grouped else first,
            "catalog_range": [first, last] if grouped else None,
            "identity": name,
            "identity_status": "grouped_directory_requires_per_id_resolution" if grouped else "resolved_from_addressables_model_directory",
            "rights_status": "excluded_porsche" if PORSCHE_RE.search(name) else "owner_authorized_non_porsche",
            "evidence_paths": sorted(set(paths))[:12],
        }
    return found


def build(catalog: dict[str, Any], apk_inventory: Any | None) -> dict[str, Any]:
    strings = strings_from_catalog(catalog)
    models = parse_model_dirs(strings)
    bundles = bundle_map(apk_inventory) if apk_inventory is not None else {}
    exact: list[dict[str, Any]] = []
    grouped: list[dict[str, Any]] = []
    for record in models.values():
        if record["catalog_id"] is not None:
            record["bundle_path"] = bundles.get(record["catalog_id"])
            exact.append(record)
        else:
            record["bundle_paths"] = {
                str(i): bundles.get(i)
                for i in range(record["catalog_range"][0], record["catalog_range"][1] + 1)
            }
            grouped.append(record)
    return {
        "format_version": 1,
        "source": "Car Parking Multiplayer recovered Addressables catalog",
        "policy": {
            "identity_gate": "Only exact named model-directory evidence resolves an individual catalog ID.",
            "grouped_directory_gate": "A range directory is family evidence, not proof that every ID has the same exact model identity.",
            "porsche": "excluded",
        },
        "counts": {
            "internal_ids": len(catalog.get("m_InternalIds", []) or []),
            "search_strings": len(strings),
            "exact_identities": len(exact),
            "grouped_directories": len(grouped),
            "bundle_paths": len(bundles),
        },
        "exact": exact,
        "grouped": grouped,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("catalog", type=Path)
    parser.add_argument("--apk-inventory", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    catalog = json.loads(args.catalog.read_text(encoding="utf-8"))
    apk = json.loads(args.apk_inventory.read_text(encoding="utf-8")) if args.apk_inventory else None
    result = build(catalog, apk)
    text = json.dumps(result, indent=2, ensure_ascii=False) + "\n"
    if args.output:
        args.output.write_text(text, encoding="utf-8")
    print(text, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
