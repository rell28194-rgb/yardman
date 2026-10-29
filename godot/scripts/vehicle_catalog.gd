extends RefCounted
class_name YardmanVehicleCatalog

const Definition = preload("res://scripts/vehicle_definition.gd")
const CONTRACT_PATH := "res://data/owner_fleet_pack_contract.json"
const DEFAULT_ID := "toyota_crown"
const FORBIDDEN_IDS := ["toyota_mark_x", "port_royal_992"]
const HELD_IDS := ["corvette_c7", "delorean_dmc12"]

const DISPLAY_OVERRIDES := {
    "toyota_crown": "Toyota Crown",
    "toyota_chaser_v": "Toyota Chaser V",
    "toyota_mark_ii": "Toyota Mark II",
    "toyota_supra_rz": "Toyota Supra RZ",
    "toyota_celica_gt77_source": "Toyota Celica GT77",
    "bmw_m3_e92_gts": "BMW M3 E92 GTS",
    "bmw_m3_e46": "BMW M3 E46",
    "bmw_m3_e36": "BMW M3 E36",
    "bmw_m3_e30": "BMW M3 E30",
    "bmw_m5_e60": "BMW M5 E60",
    "bmw_m2": "BMW M2",
    "bmw_m4": "BMW M4",
    "audi_r8": "Audi R8",
    "honda_s2000": "Honda S2000",
    "lexus_lfa": "Lexus LFA",
    "mazda_mx5": "Mazda MX-5",
    "mazda_rx7": "Mazda RX-7",
    "mazda_rx7_fc": "Mazda RX-7 FC",
    "mercedes_c63": "Mercedes-Benz C63",
    "mitsubishi_evo9": "Mitsubishi Evo IX",
    "mitsubishi_evox": "Mitsubishi Evo X",
    "nissan_180sx": "Nissan 180SX",
    "nissan_350z": "Nissan 350Z",
    "nissan_s30z": "Nissan S30Z",
    "nissan_skyline_r32": "Nissan Skyline R32",
    "nissan_skyline_r33": "Nissan Skyline R33",
    "nissan_skyline_r34": "Nissan Skyline R34",
    "nissan_skyline_r35": "Nissan Skyline R35",
    "subaru_wrx": "Subaru WRX",
    "dodge_srt10": "Dodge SRT-10",
    "dodge_viper_gts": "Dodge Viper GTS",
    "dodge_challenger_rt": "Dodge Challenger R/T",
    "chevrolet_camaro": "Chevrolet Camaro",
    "carx_ae86_a": "Toyota AE86 · Source A",
    "carx_ae86_b": "Toyota AE86 · Source B",
    "carx_charger_source": "Charger · CarX Source",
    "carx_civic_source": "Civic · CarX Source",
    "carx_nsx_source": "NSX · CarX Source",
    "carx_peterbilt": "Peterbilt · CarX",
    "carx_truck_peterbilt": "Peterbilt Truck · CarX",
    "carx_pontiac_solstice": "Pontiac Solstice · CarX",
    "carx_pontiac_trans_am_77": "Pontiac Trans Am '77 · CarX",
    "carx_maloo_r8": "Maloo R8 · CarX",
    "carx_commodore": "Commodore · CarX",
    "carx_cuda_70": "Cuda '70 · CarX",
    "carx_drift_shool_car": "Drift School Car · CarX",
    "carx_driftbuster": "Driftbuster · CarX",
    "carx_driftwagon": "Driftwagon · CarX",
    "carx_van_livery": "Van Livery · CarX",
    "carx_van_paint": "Van Paint · CarX",
    "carx_vaz2102_paint": "VAZ 2102 · CarX",
    "carx_vaz2107": "VAZ 2107 · CarX",
}

static var _ids: Array[String] = []
static var _loaded := false

static func _ensure_loaded() -> void:
    if _loaded:
        return
    _loaded = true
    _ids.clear()
    if FileAccess.file_exists(CONTRACT_PATH):
        var payload = JSON.parse_string(FileAccess.get_file_as_string(CONTRACT_PATH))
        if payload is Dictionary and int(payload.get("format_version", 0)) == 1:
            for raw_id in payload.get("available_vehicle_ids", []):
                _add_legacy_id(str(raw_id))
    # Source-reconciled definitions are the expansion path beyond Fleet64. Only
    # runtime-ready definitions enter the selectable production catalog; a
    # DISCOVERED/RECOVERED vehicle remains invisible until its own gates pass.
    for vehicle_id in Definition.registry_ids(true):
        _add_id(vehicle_id)
    if not _ids.has(DEFAULT_ID):
        _ids.append(DEFAULT_ID)
    _ids.sort()

static func _add_legacy_id(vehicle_id: String) -> void:
    if vehicle_id.is_empty() or FORBIDDEN_IDS.has(vehicle_id) or HELD_IDS.has(vehicle_id):
        return
    _add_id(vehicle_id)

static func _add_id(vehicle_id: String) -> void:
    if vehicle_id.is_empty() or _ids.has(vehicle_id):
        return
    _ids.append(vehicle_id)

static func production_ids() -> Array[String]:
    _ensure_loaded()
    return _ids.duplicate()

static func has(vehicle_id: String) -> bool:
    _ensure_loaded()
    return _ids.has(vehicle_id)

static func hero_scene(vehicle_id: String) -> String:
    if Definition.runtime_ready(vehicle_id):
        var source_scene := Definition.primary_scene(vehicle_id)
        if not source_scene.is_empty():
            return source_scene
    if vehicle_id == DEFAULT_ID:
        return "toyota_crown_2013.glb"
    if vehicle_id == "toyota_chaser_v":
        return "road_car.glb"
    if vehicle_id.begins_with("carx_") and vehicle_id != "carx_ae86_a" and vehicle_id != "carx_ae86_b":
        return vehicle_id + ".glb"
    return "fleet_" + vehicle_id + ".glb"

static func display_name(vehicle_id: String) -> String:
    var definition := Definition.load_definition(vehicle_id)
    if not definition.is_empty():
        var source_name := str(definition.get("display_name", ""))
        if not source_name.is_empty():
            return source_name
    if DISPLAY_OVERRIDES.has(vehicle_id):
        return str(DISPLAY_OVERRIDES[vehicle_id])
    var words := vehicle_id.replace("_source", "").replace("carx_", "").split("_")
    var result: Array[String] = []
    for word in words:
        if word.length() <= 3 and word.to_upper() in ["BMW", "WRX", "GTS", "R8"]:
            result.append(word.to_upper())
        else:
            result.append(word.capitalize())
    return " ".join(result)

static func profile(vehicle_id: String) -> Dictionary:
    var resolved := vehicle_id if has(vehicle_id) else DEFAULT_ID
    var definition := Definition.load_definition(resolved)
    var source_backed := not definition.is_empty()
    return {
        "id": resolved,
        "display_name": display_name(resolved),
        "hero_scene": hero_scene(resolved),
        "source_backed": source_backed,
        "source_status": Definition.status(resolved),
        "runtime_ready": Definition.runtime_ready(resolved),
        "hierarchy_descriptor": Definition.hierarchy_path(resolved),
        "inspection_scene": Definition.inspection_scene(resolved),
        "dynamics": Definition.dynamics(resolved),
        "customization": Definition.customization(resolved),
        "upgrades": Definition.upgrades(resolved),
        "source": Definition.source_summary(resolved),
    }

static func reload() -> void:
    Definition.clear_cache()
    _ids.clear()
    _loaded = false
