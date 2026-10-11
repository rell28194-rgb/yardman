#!/usr/bin/env python3
"""Disposition every saved Unity object without inventing missing dependencies.

This is a recovery worklist, not an acceptance gate.  Types identify payload
roles; token rules identify provisional semantic groups.  Lexical groups never
establish a prefab, a material binding, content neutrality, geography or quality.
Full per-object identities/hashes stay in private manifests.  The optional public
report contains aggregate metadata only and no recovered payloads.
"""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from contextlib import contextmanager
import gzip
import hashlib
import json
import math
from pathlib import Path
import re
import sys
import unicodedata


FORMAT_VERSION = 1
RULESET_VERSION = "unity-family-worklist-1"
OWNER_CATEGORIES = (
    "vehicles", "vehicle_parts", "road_surfaces", "road_markings", "barriers",
    "signage", "buildings", "storefronts", "street_furniture", "vegetation",
    "terrain_coastal", "water", "props", "textures_materials", "characters",
    "animations", "hud_ui", "audio", "vfx", "shaders", "reference_systems",
)
LEDGER_MAP = {
    category: ("road_markings_barriers_signage" if category in
               {"road_markings", "barriers", "signage"} else
               "characters_animations" if category in {"characters", "animations"}
               else category)
    for category in OWNER_CATEGORIES
}
LEDGER_CATEGORIES = tuple(dict.fromkeys(LEDGER_MAP.values()))

# Engine containers are recognized by container identity, not asset names.
BUILTIN_CONTAINERS = {"unity default resources", "unity_builtin_extra"}
MEDIA_TYPES = {"Mesh", "Texture2D", "Texture3D", "Texture2DArray", "Cubemap",
               "AudioClip", "AnimationClip", "Sprite", "Font", "MovieTexture"}
MATERIAL_TYPES = {"Material", "PhysicMaterial", "PhysicsMaterial2D"}
SHADER_TYPES = {"Shader", "ComputeShader", "CGProgram"}
SCRIPT_TYPES = {"MonoBehaviour", "MonoScript", "TextAsset"}
RIG_TYPES = {"Avatar", "AnimatorController", "AnimatorOverrideController"}
SCENE_TYPES = {"GameObject", "Transform", "RectTransform"}
UI_SUPPORT_TYPES = {"Canvas", "CanvasGroup", "CanvasRenderer", "GUIText", "TextMesh"}
ANIMATION_SUPPORT_TYPES = {"Animator", "Animation"}
VFX_SUPPORT_TYPES = {"ParticleSystem", "ParticleSystemRenderer", "TrailRenderer",
                     "LineRenderer", "Flare", "LensFlare", "FlareLayer", "Projector"}
AUDIO_SUPPORT_TYPES = {"AudioSource", "AudioListener", "AudioMixerController",
                       "AudioMixerGroupController", "AudioMixerSnapshotController"}
ENVIRONMENT_SUPPORT_TYPES = {"LightProbes", "ReflectionProbe", "RenderSettings",
                            "LightmapSettings", "LightingSettings", "OcclusionCullingData",
                            "OcclusionCullingSettings", "OcclusionArea", "NavMeshSettings"}
PHYSICS_SUPPORT_TYPES = {"Rigidbody", "Rigidbody2D", "BoxCollider", "BoxCollider2D",
                        "CapsuleCollider", "SphereCollider", "MeshCollider", "WheelCollider",
                        "ConfigurableJoint", "HingeJoint", "CharacterController"}
RENDER_SUPPORT_TYPES = {"MeshFilter", "MeshRenderer", "SkinnedMeshRenderer",
                       "SpriteRenderer", "LODGroup", "Camera", "Light", "VideoPlayer"}
CONTAINER_TYPES = {"AssetBundle", "AssetBundleManifest", "PreloadData"}
GLOBAL_TYPES = {
    "BuildSettings", "PlayerSettings", "InputManager", "TagManager", "AudioManager",
    "ScriptMapper", "MonoManager", "GraphicsSettings", "TimeManager", "DelayedCallManager",
    "PhysicsManager", "QualitySettings", "ResourceManager", "NavMeshProjectSettings",
    "Physics2DSettings", "RuntimeInitializeOnLoadManager", "UnityConnectSettings",
    "StreamingManager", "VFXManager", "CloudWebServicesManager", "UnityAnalyticsManager",
    "CrashReportManager", "PerformanceReportingManager", "NetworkManager",
}


def normalized_name(name: str | None) -> str:
    """Split case and separators; preserve numbers and the original private name."""
    value = re.sub(r"([a-z])([A-Z])", r"\1 \2", name or "")
    value = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1 \2", value)
    value = value.replace("ł", "l").replace("Ł", "L")
    value = unicodedata.normalize("NFKD", value)
    value = "".join(c for c in value if not unicodedata.combining(c))
    return " ".join(re.sub(r"[^a-z0-9]+", " ", value.lower()).split())


def cluster_stem(name: str | None) -> str:
    """Only strip explicit exporter/LOD suffixes; numbered kits remain distinct."""
    value = re.sub(r"\s*\(\d+\)\s*$", "", name or "")
    value = re.sub(r"\.\d{3}$", "", value)
    value = re.sub(r"(?:[_\s-]lod[_\s-]?\d+)\s*$", "", value, flags=re.I)
    return normalized_name(value) or "unnamed"


def rule(category: str, group: str, pattern: str):
    return category, group, re.compile(pattern)


# Conservative whole-token rules prevent camera/cardboard => car, grass => glass,
# or map-sign HUD icons => accepted road signage.  Matches remain hints only.
SEMANTIC_RULES = (
    rule("hud_ui", "ui_icons_layout", r"\b(?:ui|gui|hud|icon|icons|sprite|label|button|popup|font|canvas|dialog|dialogs|minimap|checkmark|scrollbar|dropdown|loading|preloader|tutorial|leaderboard|leaderboards|menu|logo|watermark)\b"),
    rule("props", "workshop_grinder_polisher", r"\b(?:szlifierka|polerka|polisher|polishing|grinder|grinding)\b"),
    rule("props", "workshop_tyre_machines", r"\b(?:wywazarka|montazownica|tirechanger|tyrechanger)\b|\b(?:tire|tyre) changer\b"),
    rule("props", "workshop_tools_lifts", r"\b(?:klucz|tool|tools|wrench|spanner|jack|podnosnik|compressor|compresor|welder|workbench|extinguisher)\b|\bimpact wrench\b"),
    rule("vehicle_parts", "engine_powertrain_components", r"\b(?:v8|v6|r4|r6|sohc|dohc|gearbox|engine|clutch|alternator|rozrusznik|gaznik|carburetor|carburettor|tlok|piston|manifold|kolektor|crankshaft|camshaft|walek|glowica|rozrzad|przepustnica|rozdzielacz|zaplonu|filtr|filter|pompa|kable|swieca|cewka|chlodnica)\b|\b(?:wal korbowy|wal n apedowy|wal napedowy|intake manifold|engine block|fuel tank)\b"),
    rule("vehicle_parts", "suspension_brakes_steering", r"\b(?:wahacz|zwrotnica|piasta|amortyzator|sprezyna|stabilizator|tuleja|sanki|polos|hamulca|hamulcowy|hamulcowa|hamulcowe|brake|brakes|caliper|calipers|steering|suspension|abs|serwo|zacisk|lozysko|sprzegla|szczeki)\b|\b(?:driver wheel|wheel drive|tarcza wentylowana)\b"),
    rule("vehicle_parts", "wheels_tyres_rims", r"\b(?:wheel|wheels|wheelstyle|wheelcap|tyre|tyres|tire|tires|opona|felga|rim|rims|spokes|diskrim|diskspokes|diskcap|blwheel|cap)\b|\b(?:wheelstyle|wheelcap|tire|tyre)\d+\b"),
    rule("vehicle_parts", "body_glass_interior_lights", r"\b(?:interior|body|bodyshell|bumper|bumpers|hood|maska|trunk|boot|fender|glass|stoplight|stoplights|headlight|headlights|taillight|taillights|mirror|mirrors|muffler|exhaust|wydech|tlumik|battery|carbattery|livery|carpaint)\b|\b(?:body|interior|steeringwheel)[hl]\b|\b(?:lights front|lights rear|lightsfront|lightsrear)\b"),
    rule("vehicle_parts", "fasteners_generic_mechanical", r"\b(?:sruba|nakretka|screw|bolt|nut|klips|korek|pret|mocowanie|obejma|bracket|fastener)\b"),
    rule("vehicles", "vehicle_roots_or_complete_meshes", r"\b(?:car|cars|bus|van|truck|trailer|naczepa|motorcycle|bike|sedan|buggy|suv|vehicle|vehicles)\b|\b(?:bmw|nissan|toyota|mazda|silvia|skyline|subaru|mitsubishi|mercedes|chevrolet|ford|audi|dodge|pontiac|peterbilt|mustang|camaro|corvette|charger|delorean|lexus|volvo|lada|vaz|ae86|mx5|e36|fury|driftwagon|driftshoolcar)[a-z0-9]*\b"),
    rule("road_markings", "paint_line_arrow_components", r"\b(?:road mark|road marking|road markings|parking lines|lane lines|lane marking|crosswalk|skidmarks|rccskidmarks)\b|\broad.*\barrow\b"),
    rule("barriers", "barrier_fence_cone_components", r"\b(?:barrier|barriers|fence|fences|bollard|bollards|guardrail|guardrails|cone|cones|gate|brama|barricade)\b"),
    rule("signage", "sign_traffic_signal_candidates", r"\b(?:sign|signage|traffic light|traffic lights|signboard|billboard|banners|banner)\b"),
    rule("road_surfaces", "road_paving_kerb_components", r"\b(?:road|roads|asphalt|asfalt|tarmac|sidewalk|sidewalks|kerb|kerbs|curb|curbs|cobble|cobbles|paving|racetrack|racetracks|track|tracks)\b"),
    rule("storefronts", "shop_garage_entrance_candidates", r"\b(?:storefront|storefronts|shop|shops|store|gas station|gasstation|myjnia|carwash|garage|garaz)\b"),
    rule("buildings", "building_module_candidates", r"\b(?:building|buildings|house|houses|hangar|hangars|barn|barns|roof|roofs|facade|facades|wall|walls|window|windows|door|doors|warehouse|stadium|tribunes|bridge|bridges)\b"),
    rule("street_furniture", "bench_bin_lamp_utility_candidates", r"\b(?:parkbench|bench|benches|dumpster|trash|bin|bins|hydrant|hydrants|electricalbox|busstop|chair|chairs|lamppost|lampost|lantern|lamplights|phone cabin|ticket machine|cabinet|cabinets|streetlight|streetlights)\b"),
    rule("vegetation", "foliage_candidate_species_unverified", r"\b(?:tree|trees|palm|palms|fern|ferns|grass|bush|bushes|shrub|shrubs|vegetation|plants|plant|flowerbed|flowerbeds|foliage|leaf|leaves|lime|garden)\b"),
    rule("terrain_coastal", "rock_ground_sand_candidates", r"\b(?:terrain|coast|coastal|shore|shoreline|rock|rocks|boulder|boulders|sand|beach|ground|gravel|dirt|earth|mountain|snow|snowy)\b"),
    rule("water", "water_surface_effect_candidates", r"\b(?:water|river|ocean|sea|lake|liquid|foam|caustic|caustics|waterfall|waves)\b"),
    rule("characters", "character_or_crowd_candidates", r"\b(?:character|characters|people|person|human|driver|crowd|crowds|npc|pedestrian|pedestrians|man|woman|skin|hair)\b"),
    rule("vfx", "particle_effect_candidates", r"\b(?:particle|particles|smoke|spark|sparks|dust|fire|flame|flare|volumetric|glow)\b"),
    rule("props", "neutral_prop_candidates", r"\b(?:prop|props|box|boxes|cardboard|barrel|barrels|crate|crates|container|containers|boombox|shelves|shelf|bottle|bottles|tank|tanks|pallet|pallets|knife|pizza|switch|screen|wardrobe|table|tables|drum)\b"),
)

WORLD_NAME_PATTERNS = (
    ("source_scene_combined_mesh", re.compile(r"\bcombined mesh\b|\broot scene\b")),
    ("named_foreign_track_or_city_context", re.compile(r"\b(?:silverstone|fiorano|bathurst|midohio|forestpark|forest park|winterfell|la obj|la town|cityblocks|city blocks|driftschool|drift school|testtrack|test track)\d*\b")),
    ("source_baked_lighting_or_minimap", re.compile(r"\b(?:lightmap|lightingdata|minimap|reflectionprobe|reflection probe)\b")),
)


def semantic_hints(name: str) -> list[dict]:
    normalized = normalized_name(name)
    matches = []
    for category, group, pattern in SEMANTIC_RULES:
        hit = pattern.search(normalized)
        if hit:
            matches.append({"category": category, "group": group, "matched": hit.group()})
    return matches


def payload_role(typ: str, source_file: str) -> str:
    if source_file in BUILTIN_CONTAINERS:
        return "engine_builtin_reference"
    if typ in MEDIA_TYPES:
        return "recoverable_media_candidate"
    if typ in MATERIAL_TYPES:
        return "material_translation_candidate"
    if typ in SHADER_TYPES:
        return "shader_reimplementation_reference"
    if typ in SCRIPT_TYPES:
        return "script_or_data_reference"
    if typ in RIG_TYPES:
        return "rig_or_controller_dependency"
    if typ in SCENE_TYPES:
        return "scene_hierarchy_reference"
    if typ in UI_SUPPORT_TYPES:
        return "unlinked_ui_support"
    if typ in ANIMATION_SUPPORT_TYPES:
        return "unlinked_animation_support"
    if typ in VFX_SUPPORT_TYPES:
        return "vfx_reimplementation_reference"
    if typ in AUDIO_SUPPORT_TYPES:
        return "unlinked_audio_support"
    if typ in ENVIRONMENT_SUPPORT_TYPES:
        return "source_environment_reference"
    if typ in PHYSICS_SUPPORT_TYPES:
        return "unlinked_physics_support"
    if typ in RENDER_SUPPORT_TYPES:
        return "unlinked_renderer_support"
    if typ in CONTAINER_TYPES:
        return "container_dependency_reference"
    if typ in GLOBAL_TYPES:
        return "engine_or_platform_system_reference"
    if typ == "RenderTexture":
        return "runtime_generated_texture_reference"
    return "unresolved_serialized_type"


def metadata_screen(record: dict) -> dict:
    """Screen saved scalar metadata, explicitly excluding geometry validation."""
    typ = record["type"]
    data = record.get("metadata", {})
    required = {
        "Mesh": ("vertices", "submeshes", "index_count"),
        "Texture2D": ("width", "height", "mip_count"),
        "AudioClip": ("length_seconds", "frequency", "channels"),
        "AnimationClip": ("sample_rate",),
    }.get(typ, ())
    if not required:
        return {"state": "not_available", "flags": []}
    flags = []
    for key in required:
        value = data.get(key)
        if (not isinstance(value, (float, int)) or isinstance(value, bool) or
                not math.isfinite(value)):
            flags.append(f"{key}_missing_or_nonfinite")
        elif value <= 0:
            flags.append(f"{key}_nonpositive")
        elif key != "length_seconds" and key != "sample_rate" and value != int(value):
            flags.append(f"{key}_not_integer")
    if typ == "AudioClip" and isinstance(data.get("channels"), (int, float)):
        if data["channels"] > 8:
            flags.append("channels_requires_multichannel_review")
    return {"state": "flagged" if flags else "scalar_metadata_present",
            "flags": flags,
            "acceptance": "not_geometry_decode_or_runtime_validation"}


def audio_group(name: str) -> str:
    value = normalized_name(name)
    if re.search(r"\b(?:music|soundtrack|muzyka|song|rock|hopsaw|breaks|drivinginmycar)\b", value):
        return "possible_soundtrack_requires_listening_disposition"
    if re.search(r"\b(?:body repair|tool|grinder|polisher|manipulacje|garage door|part drop|car wash|car detailing|laquer|tearing|box open)\b", value):
        return "workshop_actions_audio"
    if re.search(r"\b(?:roll|skid|slide|friction|gravel|grass|sand|cobbles|snow|brick|crash|impact|carimpact\d*)\b", value):
        return "surface_contact_collision_audio"
    if re.search(r"\b(?:idle|rpm|\d+rpm|onmid|onlow|onhigh|offmid|offlow|offhigh|engine|exhaust|turbo|boff|blowoff|brakes|gearshifting\d*|gear|nos)\b|\b(?:on|off) (?:mid|low|high)\b|\b(?:e36|buggy|generic|sport\d+|suv) (?:high|med|low)\b", value):
        return "vehicle_engine_mechanical_audio"
    if re.search(r"\b(?:sfx|cash|success|tap|money|finish|checkpoint|check point|servo|counter)\b", value):
        return "interface_actions_audio"
    if re.search(r"\b(?:wind|step\d*|footstep|birds|ambient|ambience)\b", value):
        return "ambience_footsteps_audio"
    return "audio_purpose_unresolved"


def intrinsic_category(typ: str) -> str | None:
    if typ in {"Texture2D", "Texture3D", "Texture2DArray", "Cubemap", "Material",
               "PhysicMaterial", "PhysicsMaterial2D", "RenderTexture"}:
        return "textures_materials"
    if typ in {"Sprite", "Font"} | UI_SUPPORT_TYPES:
        return "hud_ui"
    if typ == "AudioClip" or typ in AUDIO_SUPPORT_TYPES:
        return "audio"
    if typ == "AnimationClip" or typ in RIG_TYPES | ANIMATION_SUPPORT_TYPES:
        return "animations"
    if typ in SHADER_TYPES:
        return "shaders"
    if typ in VFX_SUPPORT_TYPES:
        return "vfx"
    if typ in SCRIPT_TYPES | GLOBAL_TYPES | ENVIRONMENT_SUPPORT_TYPES | CONTAINER_TYPES:
        return "reference_systems"
    return None


def classify_record(record: dict, source: str) -> dict:
    typ = record["type"]
    role = payload_role(typ, record["file"])
    name = record.get("name") or ""
    hints = semantic_hints(name)
    intrinsic = intrinsic_category(typ)
    # Every script/data record is reference-only, however asset-like its name.
    if role in {"engine_builtin_reference", "script_or_data_reference",
                "engine_or_platform_system_reference", "source_environment_reference",
                "container_dependency_reference"}:
        primary = "reference_systems"
    elif intrinsic:
        primary = intrinsic
    elif hints:
        primary = hints[0]["category"]
    else:
        primary = None
    categories = sorted({hint["category"] for hint in hints} | ({primary} if primary else set()))
    if typ == "AudioClip":
        # An engine idle recording is audio, not character animation.
        categories = ["audio"]
        group = audio_group(name)
    elif typ in {"Sprite", "Font"}:
        # Character portraits and car icons are UI media, not 3D characters/cars.
        categories = ["hud_ui"]
        group = "ui_sprite_or_font_media"
    elif hints:
        group = hints[0]["group"]
    else:
        group = intrinsic or role
    world_flags = [key for key, pattern in WORLD_NAME_PATTERNS if pattern.search(normalized_name(name))]
    if role == "source_environment_reference":
        world_flags.append("scene_specific_environment_payload")
    scene_missing = typ in SCENE_TYPES | RENDER_SUPPORT_TYPES | PHYSICS_SUPPORT_TYPES
    role_candidate = role in {"recoverable_media_candidate", "material_translation_candidate"}
    if role == "unresolved_serialized_type":
        disposition = "unresolved_type_requires_parser_inspection"
    elif scene_missing:
        disposition = "unlinked_hierarchy_or_component"
    elif role_candidate:
        disposition = "candidate_requires_dependencies_and_validation"
    else:
        disposition = "support_or_reference_only"
    if role_candidate and not name and not intrinsic:
        disposition = "unresolved_unnamed_media"
    if role_candidate and name and not primary:
        disposition = "unresolved_semantic_media"
    # No category is accepted/rejected/absent from a token match.
    identity = f"{source}:{record['file']}:{record['path_id']}"
    family_kind = "provisional_semantic_cluster" if name else "explicit_support_or_unresolved_bucket"
    cluster_name = cluster_stem(name) if name else "unnamed"
    family_key = [source, record["file"], typ, role, group, cluster_name]
    family_id = source + "-" + hashlib.sha256(json.dumps(family_key, ensure_ascii=False).encode()).hexdigest()[:20]
    return {
        "identity": identity,
        "family_id": family_id,
        "family_kind": family_kind,
        "primary_category": primary,
        "category_hints": categories,
        "ledger_categories": sorted({LEDGER_MAP[c] for c in categories}),
        "payload_role": role,
        "disposition": disposition,
        "semantic_group": group,
        "semantic_evidence": hints,
        "world_context_flags": sorted(set(world_flags)),
        "world_layout_substitution_allowed": False,
        "neutrality": "unverified_requires_content_inspection" if role_candidate else "not_a_portable_media_acceptance",
        "metadata_screen": metadata_screen(record),
        "dependency_state": "not_retained_in_saved_inventory",
        "acceptance_state": "not_accepted",
        "extraction_state": "not_extracted_by_this_pass",
    }


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


@contextmanager
def gzip_writer(path: Path):
    # Fixed mtime and omitted gzip filename produce repeatable checkpoint hashes.
    with path.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as stream:
            yield stream


def validate_record(record: dict, seen: set, line: int) -> None:
    for field in ("file", "path_id", "type", "byte_start", "byte_size", "sha256", "name"):
        if field not in record:
            raise ValueError(f"line {line}: missing {field}")
    for field in ("file", "type"):
        if not isinstance(record[field], str) or not record[field]:
            raise ValueError(f"line {line}: invalid {field}")
    if record["name"] is not None and not isinstance(record["name"], str):
        raise ValueError(f"line {line}: invalid name")
    for field in ("path_id", "byte_start", "byte_size"):
        if not isinstance(record[field], int) or isinstance(record[field], bool):
            raise ValueError(f"line {line}: invalid {field}")
    if record["byte_start"] < 0 or record["byte_size"] < 0:
        raise ValueError(f"line {line}: negative byte location/size")
    if not isinstance(record["sha256"], str) or not re.fullmatch(r"[a-f0-9]{64}", record["sha256"]):
        raise ValueError(f"line {line}: invalid SHA-256")
    identity = (record["file"], record["path_id"])
    if identity in seen:
        raise ValueError(f"line {line}: duplicate object identity {identity}")
    seen.add(identity)


DEPENDENCY_BLOCKERS = (
    "Saved inventories omit GameObject component pointers, Transform parents/children and prefab roots.",
    "Saved inventories omit mesh/material bindings, texture/stream pointers and external file IDs.",
    "Serialized object SHA-256 covers its record bytes, not referenced texture/audio resource payload bytes.",
    "Scalar vertex/index metadata does not validate topology, bounds, metre scale, orientation or normals.",
    "Names only create worklist hints; neutrality, species, branding and location require content inspection.",
    "No conversion, Compatibility capture, listening, runtime integration or Android-device test occurs in this pass.",
)


def category_rows(category_counts: dict, families: dict, total: int) -> dict:
    rows = {}
    for category in OWNER_CATEGORIES:
        counts = category_counts[category]
        candidate_families = sum(category in f["category_hints"] and f["payload_role"] in
                                 {"recoverable_media_candidate", "material_translation_candidate"}
                                 for f in families.values())
        rows[category] = {
            "ledger_category": LEDGER_MAP[category],
            "inventory_records_evaluated": total,
            "objects_with_type_or_name_hints": counts["objects"],
            "recoverable_media_candidates": counts["recoverable_media_candidate"],
            "material_translation_candidates": counts["material_translation_candidate"],
            "hierarchy_component_reference_objects": counts["hierarchy_support"],
            "other_reference_objects": counts["reference"],
            "candidate_semantic_clusters": candidate_families,
            "extracted_families": 0,
            "technically_validated_families": 0,
            "render_or_listening_validated_families": 0,
            "integrated_families": 0,
            "explicit_content_rejections": 0,
            "disposition": "candidate_worklist_open" if counts["objects"] else "unresolved_no_identifying_hint",
            "absence_confirmed": False,
            "blockers": ["Recover graph/stream dependencies from source containers; inspect content and complete applicable acceptance checks."],
        }
    return rows


def classify_source(objects_path: Path, summary_path: Path, out_dir: Path) -> dict:
    summary = json.loads(summary_path.read_text(encoding="utf-8"))
    source = summary["source_family"]
    if not re.fullmatch(r"[a-zA-Z0-9_-]+", source):
        raise ValueError("unsafe source identifier")
    for error_key in ("parse_errors", "metadata_errors", "hash_errors"):
        if summary.get(error_key):
            raise ValueError(f"source summary reports {error_key}; incomplete input cannot certify full static coverage")
    source_dir = out_dir / source
    source_dir.mkdir(parents=True, exist_ok=True)
    objects_output = source_dir / "classified-objects.ndjson.gz"
    families_output = source_dir / "families.ndjson.gz"
    seen = set()
    types = Counter()
    roles = Counter()
    dispositions = Counter()
    scalar_flags = Counter()
    semantic_groups = Counter()
    media_semantic_groups = Counter()
    context_flags = Counter()
    category_counts = defaultdict(Counter)
    families = {}
    exact_hashes = defaultdict(list)
    count = 0
    with gzip_writer(objects_output) as output:
        opener = gzip.open if objects_path.suffix == ".gz" else open
        with opener(objects_path, "rt", encoding="utf-8") as stream:
            for line_number, line in enumerate(stream, 1):
                if not line.strip():
                    raise ValueError(f"line {line_number}: empty record")
                record = json.loads(line)
                validate_record(record, seen, line_number)
                classified = classify_record(record, source)
                out = {**record, "classification": classified}
                output.write((json.dumps(out, separators=(",", ":"), ensure_ascii=False) + "\n").encode())
                count += 1
                types[record["type"]] += 1
                role = classified["payload_role"]
                roles[role] += 1
                dispositions[classified["disposition"]] += 1
                scalar_flags.update(classified["metadata_screen"]["flags"])
                semantic_groups[classified["semantic_group"]] += 1
                context_flags.update(classified["world_context_flags"])
                if role in {"recoverable_media_candidate", "material_translation_candidate"}:
                    media_semantic_groups[classified["semantic_group"]] += 1
                for category in classified["category_hints"]:
                    category_counts[category]["objects"] += 1
                    category_counts[category][role] += 1
                    if role.startswith("unlinked_") or role == "scene_hierarchy_reference":
                        category_counts[category]["hierarchy_support"] += 1
                    elif role not in {"recoverable_media_candidate", "material_translation_candidate"}:
                        category_counts[category]["reference"] += 1
                family_id = classified["family_id"]
                if family_id not in families:
                    families[family_id] = {
                        "id": family_id, "source": source, "source_file": record["file"],
                        "serialized_type": record["type"], "payload_role": role,
                        "kind": classified["family_kind"], "semantic_group": classified["semantic_group"],
                        "lexical_stem": cluster_stem(record["name"]),
                        "category_hints": classified["category_hints"],
                        "ledger_categories": classified["ledger_categories"],
                        "disposition": classified["disposition"], "objects": [],
                        "state": "candidate" if role in {"recoverable_media_candidate", "material_translation_candidate"} else "reference_or_unresolved",
                        "dependency_linkage": "unproven; file/type/name cluster is not a prefab or dependency family",
                        "technical_validation": "not_performed", "visual_audio_validation": "not_performed",
                        "integration": "not_integrated", "rejection": None,
                    }
                family = families[family_id]
                # A lexical merge cannot erase divergent per-object category hints.
                family["category_hints"] = sorted(set(family["category_hints"]) | set(classified["category_hints"]))
                family["ledger_categories"] = sorted({LEDGER_MAP[c] for c in family["category_hints"]})
                family["objects"].append({"identity": classified["identity"], "path_id": record["path_id"],
                                          "sha256": record["sha256"], "byte_start": record["byte_start"],
                                          "byte_size": record["byte_size"], "name": record["name"]})
                exact_hashes[(record["type"], record["sha256"])].append(classified["identity"])
    if count != summary["object_count"]:
        raise ValueError(f"source count mismatch: classified {count}, expected {summary['object_count']}")
    if dict(types) != summary["serialized_type_counts"]:
        raise ValueError("serialized type counts mismatch; saved summary and object inventory differ")
    expected_coverage = summary.get("coverage", {})
    if not expected_coverage.get("serialized_type_inventory_complete") or not expected_coverage.get("object_identity_hashes_complete"):
        raise ValueError("source summary does not certify complete static identities/types")
    if sum(len(f["objects"]) for f in families.values()) != count:
        raise ValueError("family membership reconciliation failure")
    with gzip_writer(families_output) as output:
        for family in sorted(families.values(), key=lambda f: f["id"]):
            family["object_count"] = len(family["objects"])
            output.write((json.dumps(family, separators=(",", ":"), ensure_ascii=False) + "\n").encode())
    duplicates = [{"serialized_type": typ, "serialized_record_sha256": digest, "identities": ids,
                   "disposition": "equal_serialized_record_bytes_only; do_not_reject_without_dependency_and_stream_comparison"}
                  for (typ, digest), ids in sorted(exact_hashes.items()) if len(ids) > 1]
    write_json(source_dir / "same-record-hash-groups.json", duplicates)
    rows = category_rows(category_counts, families, count)
    type_accounting = {
        typ: {"input_objects": total, "classified_objects": total,
              "payload_role": payload_role(typ, "non_builtin"),
              "note": "Builtin container identities override this type's role per record."}
        for typ, total in sorted(types.items())
    }
    report = {
        "format_version": FORMAT_VERSION, "ruleset_version": RULESET_VERSION, "source_id": source,
        "input_inventory_sha256": file_sha256(objects_path), "input_summary_sha256": file_sha256(summary_path),
        "classification_coverage": {
            "input_records": count, "records_dispositioned": count, "unique_identities": len(seen),
            "all_static_records_dispositioned": True, "type_accounting_reconciled": True,
            "family_membership_reconciled": True, "unassigned_records": 0,
            "linked_family_classification_complete": False, "integration_accepted": False,
        },
        "payload_role_counts": dict(sorted(roles.items())),
        "disposition_counts": dict(sorted(dispositions.items())),
        "serialized_type_accounting": type_accounting,
        "semantic_cluster_count": len(families),
        "candidate_media_cluster_count": sum(f["state"] == "candidate" for f in families.values()),
        "semantic_group_counts": dict(sorted(semantic_groups.items())),
        "candidate_media_semantic_group_counts": dict(sorted(media_semantic_groups.items())),
        "metadata_screen_flag_counts": dict(sorted(scalar_flags.items())),
        "world_context_flag_counts": dict(sorted(context_flags.items())),
        "owner_category_matrix": rows,
        "owner_to_ledger_category_map": LEDGER_MAP,
        "same_serialized_record_hash_groups": len(duplicates),
        "duplicate_rejections": 0,
        "recovered_families": 0, "accepted_families": 0,
        "content_rejections": [],
        "policy_dispositions": [
            {"scope": "source scene/root/lighting/map layout payloads", "decision": "hold for reference and component inspection",
             "reason": "Owner requires registered Jamaica world data. Source layouts cannot substitute for Jamaica geography.",
             "content_rejection_claim": False},
            {"scope": "MonoBehaviour, MonoScript, TextAsset, engine/runtime objects", "decision": "reference_only",
             "reason": "Serialized Unity scripts/system data are not direct Godot media; asset pointers must be resolved independently.",
             "content_rejection_claim": False},
        ],
        "remaining_blockers": list(DEPENDENCY_BLOCKERS),
        "raw_source_requirements": summary["sources"],
        "private_artifacts": {
            "classified_objects": {"name": objects_output.name, "sha256": file_sha256(objects_output)},
            "families": {"name": families_output.name, "sha256": file_sha256(families_output)},
            "same_record_hash_groups": {"name": "same-record-hash-groups.json", "sha256": file_sha256(source_dir / "same-record-hash-groups.json")},
        },
    }
    write_json(source_dir / "classification-summary.json", report)
    return report


def public_report(reports: list[dict]) -> dict:
    # Reports contain only aggregates, hashes and non-private derived metadata.
    # Raw names, object identities, lexical stems and object lists stay private.
    return {
        "format_version": FORMAT_VERSION, "ruleset_version": RULESET_VERSION,
        "classifier": {"path": "godot/tools/classify_unity_families.py", "sha256": file_sha256(Path(__file__))},
        "scope": "Car Mechanic 21 and CarX Drift complete saved-object disposition pass; Beta 1 remains open",
        "method": "Typed payload-role accounting plus provisional token clusters; no hierarchy or dependency assertions from names.",
        "acceptance": "No recovered family accepted/rejected as content. No visual, audio, runtime or device acceptance is claimed.",
        "owner_categories": list(OWNER_CATEGORIES), "ledger_categories": list(LEDGER_CATEGORIES),
        "owner_to_ledger_category_map": LEDGER_MAP,
        "sources": reports,
    }


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inventory-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True, help="Private output outside public Git")
    parser.add_argument("--source", action="append", required=True, help="Source prefix; repeat for independent sources")
    parser.add_argument("--public-report", type=Path)
    args = parser.parse_args(argv)
    repo_root = Path(__file__).resolve().parents[2]
    out = args.output_dir.resolve()
    if out == repo_root or repo_root in out.parents:
        parser.error("private manifests must be outside the Godot/public repository tree")
    reports = []
    try:
        for source in args.source:
            if not re.fullmatch(r"[a-zA-Z0-9_-]+", source):
                raise ValueError("unsafe source argument")
            reports.append(classify_source(args.inventory_dir / f"{source}-objects.ndjson.gz",
                                           args.inventory_dir / f"{source}-unity-summary.json", out))
        if args.public_report:
            write_json(args.public_report, public_report(reports))
    except (ValueError, KeyError, OSError, json.JSONDecodeError) as error:
        print(f"classification failed: {error}", file=sys.stderr)
        return 1
    for report in reports:
        coverage = report["classification_coverage"]
        print(f"{report['source_id']}: dispositioned {coverage['records_dispositioned']} saved records; "
              f"{report['candidate_media_cluster_count']} provisional media clusters; linked recovery/acceptance open")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
