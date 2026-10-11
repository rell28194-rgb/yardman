"""Derive asset-stage eligibility without treating internal builds as completion."""

import argparse
import json
from pathlib import Path

CATEGORIES = (
    "vehicles", "vehicle_parts", "road_surfaces", "road_markings_barriers_signage",
    "buildings", "storefronts", "street_furniture", "vegetation", "terrain_coastal",
    "water", "props", "textures_materials", "characters_animations", "hud_ui",
    "audio", "vfx", "shaders", "reference_systems",
)
VISUAL = set(CATEGORIES) - {"audio", "reference_systems"}
REGRESSIONS = {
    "foliage_atlas_alpha", "sedan_triangles_lighting", "material_translation",
    "scale_orientation", "collision", "road_geometry", "coast_placement",
}
DEFAULT_LEDGER = Path(__file__).resolve().parents[1] / "docs/asset_recovery/ledger.json"


def evidence(value):
    return isinstance(value, str) and bool(value.strip())


def unique_by_id(records, context):
    if not isinstance(records, list):
        raise ValueError(f"{context}: expected an array")
    result = {}
    for record in records:
        key = record.get("id") if isinstance(record, dict) else None
        if not evidence(key) or key in result:
            raise ValueError(f"{context}: missing or duplicate ID {key!r}")
        result[key] = record
    return result


def library_blockers(library, name):
    blockers = []
    if library.get("outer_inventory_complete") is not True:
        blockers.append(f"{name}: outer inventory incomplete")
    sources = unique_by_id(library.get("sources"), f"{name} sources")
    families = unique_by_id(library.get("families"), f"{name} families")
    members = library.get("archive_members", [])
    ignored = library.get("ignored_archive_members", [])
    if not isinstance(members, list) or any(not evidence(i) for i in members) or len(members) != len(set(members)):
        raise ValueError(f"{name}: invalid archive member index")
    covered = [m for source in sources.values() for m in source.get("members", [])]
    for item in ignored:
        if not evidence(item.get("reason")):
            raise ValueError(f"{name}: ignored archive member lacks a reason")
        covered.append(item.get("path"))
    if len(covered) != len(set(covered)) or set(covered) != set(members):
        raise ValueError(f"{name}: source coverage does not match the complete outer member index")
    if not members or not evidence(library.get("inventory_evidence")):
        blockers.append(f"{name}: outer inventory evidence missing")
    categories = library.get("categories")
    if not isinstance(categories, dict) or set(categories) != set(CATEGORIES):
        raise ValueError(f"{name}: every coverage category must be explicitly recorded")
    if not sources:
        blockers.append(f"{name}: no source inventories recorded")
    classified = {category: set() for category in CATEGORIES}
    for source_id, source in sources.items():
        state = source.get("state")
        if state not in {"pending", "inventoried", "duplicate", "rejected"}:
            raise ValueError(f"{name}/{source_id}: invalid source state")
        if state == "pending":
            blockers.append(f"{name}/{source_id}: inner inventory pending")
            continue
        proof = source.get("evidence", {})
        required = {"inspection", "reason"} if state == "rejected" else {"inventory", "hashes"}
        if state == "duplicate":
            required.add("content_comparison")
        if any(not evidence(proof.get(key)) for key in required):
            blockers.append(f"{name}/{source_id}: source evidence incomplete")
        coverage = source.get("classification", {})
        if state == "rejected":
            continue
        if set(coverage) != set(CATEGORIES):
            blockers.append(f"{name}/{source_id}: all-type category classification incomplete")
        for category, record in coverage.items():
            if category not in CATEGORIES:
                raise ValueError(f"{name}/{source_id}: unknown category {category}")
            ids = record.get("family_ids", [])
            if not evidence(record.get("evidence")) or not isinstance(ids, list):
                blockers.append(f"{name}/{source_id}/{category}: classification evidence missing")
                continue
            for family_id in ids:
                if family_id not in families or families[family_id].get("source_id") != source_id:
                    raise ValueError(f"{name}: classification refers to an unknown/wrong-source family")
                classified[category].add(family_id)
    for category, record in categories.items():
        ids = record.get("family_ids", [])
        if not isinstance(ids, list) or len(ids) != len(set(ids)) or any(i not in families for i in ids):
            raise ValueError(f"{name}/{category}: invalid family references")
        if record.get("reviewed") is not True or not evidence(record.get("evidence")):
            blockers.append(f"{name}/{category}: exhaustive review pending")
        if set(ids) != classified[category]:
            blockers.append(f"{name}/{category}: source/category family coverage differs")
    for family_id, family in families.items():
        if family.get("source_id") not in sources:
            raise ValueError(f"{name}/{family_id}: unknown source")
        assigned = {c for c, r in categories.items() if family_id in r.get("family_ids", [])}
        if not assigned:
            blockers.append(f"{name}/{family_id}: category classification missing")
        state = family.get("state")
        if state not in {"pending", "validation_pending", "integrated", "reference", "rejected"}:
            raise ValueError(f"{name}/{family_id}: invalid family state")
        proof = family.get("evidence", {})
        if state == "rejected":
            required = {"inspection", "reason"}
        elif state == "reference":
            required = {"analysis", "reimplementation_test", "batch"}
        elif state == "integrated":
            required = {"import", "normalize", "runtime", "batch"}
            if assigned & VISUAL:
                required.add("render")
            if "audio" in assigned:
                required.add("listening")
            if name == "beta2":
                required.add("quality_comparison")
        else:
            blockers.append(f"{name}/{family_id}: recovery/validation pending")
            continue
        if any(not evidence(proof.get(key)) for key in required):
            blockers.append(f"{name}/{family_id}: {state} evidence incomplete")
    return blockers


def validate(ledger):
    if ledger.get("format_version") != 1:
        raise ValueError("Unsupported asset ledger format")
    libraries = ledger.get("libraries", {})
    if set(libraries) != {"beta1", "beta2"}:
        raise ValueError("Both libraries must be recorded")
    first = library_blockers(libraries["beta1"], "beta1")
    regressions = unique_by_id(ledger.get("regressions"), "regressions")
    if not REGRESSIONS.issubset(regressions):
        raise ValueError("Required regression coverage is missing")
    unresolved = []
    for regression_id, regression in regressions.items():
        proof = regression.get("evidence", {})
        if regression.get("state") != "resolved" or any(
            not evidence(proof.get(key)) for key in ("test", "render_or_runtime", "batch")
        ):
            unresolved.append(f"regression/{regression_id}: acceptance pending")
    first += unresolved
    if libraries["beta2"].get("started") is True and first:
        raise ValueError("Beta 2 started before Beta 1 completion and regression acceptance")
    second = library_blockers(libraries["beta2"], "beta2")
    polish = ledger.get("polish_acceptance", {})
    final = first + second
    if polish.get("complete") is not True or any(not evidence(polish.get(key)) for key in (
        "game_render", "controls_driving", "world_coast_roads", "android_runtime",
    )):
        final.append("final polish/gameplay/Android runtime acceptance pending")
    return {
        "beta1_complete": not first, "beta2_complete": not second,
        "beta2_allowed": not first, "final_packaging_allowed": not final,
        "beta1_blockers": first, "beta2_blockers": second,
        "final_packaging_blockers": final, "internal_android_builds_allowed": True,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ledger", type=Path, default=DEFAULT_LEDGER)
    parser.add_argument("--require", choices=("beta2", "final_packaging"))
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        report = validate(json.loads(args.ledger.read_text()))
    except (ValueError, TypeError, AttributeError, KeyError) as error:
        parser.exit(1, f"Invalid asset ledger: {error}\n")
    encoded = json.dumps(report, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded)
    print(encoded, end="")
    if args.require and not report[f"{args.require}_allowed"]:
        parser.exit(1, f"Blocked: {args.require}; finish the recorded recovery/acceptance work.\n")


if __name__ == "__main__":
    main()
