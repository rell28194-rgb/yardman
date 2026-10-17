#!/usr/bin/env python3
"""Source-evidence semantics for Jamaica building reconstruction.

This module deliberately separates source truth from presentation inference.
It normalizes declared envelope materials and use context so OSM/simple-3D data,
recovered building families, terrain-derived structure and regional grammar can
share one compact vocabulary without erasing original source values.
"""
from __future__ import annotations

FALSE_VALUES = {"", "0", "false", "no"}
WALL_KEYS = ("building:material", "building:cladding", "cladding", "facade:material")
ROOF_KEYS = ("roof:material",)
COLOUR_KEYS = ("building:colour", "roof:colour")
USE_KEYS = ("building:use", "amenity", "tourism", "shop", "office", "industrial", "craft", "leisure", "historic")

MATERIAL_ALIASES = {
    "zinc": "metal",
    "zinc_sheet": "metal",
    "zinc_sheets": "metal",
    "galvanised": "metal",
    "galvanized": "metal",
    "galvanised_steel": "metal",
    "galvanized_steel": "metal",
    "corrugated": "metal",
    "corrugated_metal": "metal",
    "corrugated_steel": "metal",
    "sheet_metal": "metal",
    "metal": "metal",
    "steel": "metal",
    "tin": "metal",
    "wood": "timber",
    "wooden": "timber",
    "timber": "timber",
    "boards": "timber",
    "board": "timber",
    "weatherboard": "timber",
    "concrete": "masonry",
    "cement_block": "masonry",
    "concrete_block": "masonry",
    "block": "masonry",
    "blocks": "masonry",
    "masonry": "masonry",
    "brick": "brick",
    "bricks": "brick",
    "stone": "stone",
    "limestone": "stone",
    "plaster": "plaster",
    "stucco": "plaster",
    "render": "plaster",
    "rendered": "plaster",
    "tile": "tile",
    "tiles": "tile",
    "roof_tiles": "tile",
    "asphalt_shingles": "shingle",
    "shingles": "shingle",
    "shingle": "shingle",
}

USE_ALIASES = {
    "school": "education",
    "college": "education",
    "university": "education",
    "kindergarten": "education",
    "hospital": "medical",
    "clinic": "medical",
    "doctors": "medical",
    "pharmacy": "medical",
    "place_of_worship": "religious",
    "church": "religious",
    "chapel": "religious",
    "mosque": "religious",
    "temple": "religious",
    "hotel": "lodging",
    "guest_house": "lodging",
    "hostel": "lodging",
    "motel": "lodging",
    "resort": "lodging",
    "supermarket": "retail",
    "convenience": "retail",
    "mall": "retail",
    "retail": "retail",
    "restaurant": "food_service",
    "fast_food": "food_service",
    "cafe": "food_service",
    "bar": "food_service",
    "pub": "food_service",
    "industrial": "industrial",
    "warehouse": "industrial",
    "factory": "industrial",
    "office": "office",
    "commercial": "commercial",
    "apartments": "residential_multi",
    "residential": "residential",
    "house": "residential",
    "detached": "residential",
    "semidetached_house": "residential",
    "terrace": "residential",
    "hut": "residential_light",
    "cabin": "residential_light",
    "shed": "outbuilding",
    "garage": "outbuilding",
    "garages": "outbuilding",
}


def clean(value) -> str:
    return str(value or "").strip().lower().replace(" ", "_")


def source_type(tags: dict) -> str:
    building = clean(tags.get("building", ""))
    if building not in FALSE_VALUES:
        return building
    part = clean(tags.get("building:part", ""))
    return part if part not in FALSE_VALUES else "yes"


def first_value(tags: dict, keys) -> str:
    for key in keys:
        value = clean(tags.get(key, ""))
        if value:
            return value
    return ""


def material_family(value) -> str:
    raw = clean(value)
    if not raw:
        return ""
    return MATERIAL_ALIASES.get(raw, raw)


def use_class(tags: dict) -> str:
    """Return the strongest declared use/class without inventing one."""
    building = source_type(tags)
    building_use = clean(tags.get("building:use", ""))
    candidates = [building_use]
    candidates.extend(clean(tags.get(key, "")) for key in USE_KEYS if key != "building:use")
    candidates.append(building)
    for value in candidates:
        if not value or value in FALSE_VALUES or value in {"yes", "building"}:
            continue
        return USE_ALIASES.get(value, value)
    return "unknown"


def source_envelope(tags: dict) -> dict:
    """Return declared envelope/use evidence; never infer a material or use."""
    result = {"use_class": use_class(tags)}
    wall_raw = first_value(tags, WALL_KEYS)
    roof_raw = first_value(tags, ROOF_KEYS)
    if wall_raw:
        result["wall_material_raw"] = wall_raw
        result["wall_material"] = material_family(wall_raw)
    if roof_raw:
        result["roof_material_raw"] = roof_raw
        result["roof_material"] = material_family(roof_raw)
    wall_colour = clean(tags.get("building:colour", ""))
    roof_colour = clean(tags.get("roof:colour", ""))
    if wall_colour:
        result["wall_colour"] = wall_colour
    if roof_colour:
        result["roof_colour"] = roof_colour
    construction = clean(tags.get("construction", ""))
    if construction or source_type(tags) == "construction":
        result["construction_state"] = construction or "yes"
    return result


def reconstruction_confidence(tags: dict, is_part: bool = False) -> str:
    """Implement the project B0-B3 evidence tiers (B4 remains bespoke/hero)."""
    if is_part or clean(tags.get("building:part", "")) not in FALSE_VALUES:
        return "B3"
    if any(clean(tags.get(key, "")) for key in (
            "height", "building:levels", "roof:levels", "roof:shape",
            "roof:height", "roof:material", "building:material",
            "building:cladding", "cladding", "facade:material")):
        return "B2"
    kind = source_type(tags)
    if kind not in {"", "yes", "building"} or use_class(tags) != "unknown":
        return "B1"
    return "B0"


def inherit_declared_envelope(child: dict, parent: dict) -> dict:
    """Fill missing part envelope/use tags from its registered parent only.

    This is inheritance of source evidence, not presentation inference. Child
    declarations always win so a timber/zinc or masonry/timber mixed building
    can remain mixed at part granularity.
    """
    result = dict(child)
    for key in WALL_KEYS + ROOF_KEYS + COLOUR_KEYS + USE_KEYS:
        if not clean(result.get(key, "")) and clean(parent.get(key, "")):
            result[key] = parent[key]
    return result
