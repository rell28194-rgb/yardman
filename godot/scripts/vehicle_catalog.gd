extends RefCounted
class_name YardmanVehicleCatalog

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
    if not FileAccess.file_exists(CONTRACT_PATH):
        _ids = [DEFAULT_ID]
        return
    var payload = JSON.parse_string(FileAccess.get_file_as_string(CONTRACT_PATH))
    if not payload is Dictionary or int(payload.get("format_version", 0)) != 1:
        _ids = [DEFAULT_ID]
        return
    for raw_id in payload.get("available_vehicle_ids", []):
        var vehicle_id := str(raw_id)
        if vehicle_id.is_empty() or FORBIDDEN_IDS.has(vehicle_id) or HELD_IDS.has(vehicle_id):
            continue
        if not _ids.has(vehicle_id):
            _ids.append(vehicle_id)
    if not _ids.has(DEFAULT_ID):
        _ids.append(DEFAULT_ID)
    _ids.sort()

static func production_ids() -> Array[String]:
    _ensure_loaded()
    return _ids.duplicate()

static func has(vehicle_id: String) -> bool:
    _ensure_loaded()
    return _ids.has(vehicle_id)

static func hero_scene(vehicle_id: String) -> String:
    if vehicle_id == DEFAULT_ID:
        return "toyota_crown_2013.glb"
    if vehicle_id == "toyota_chaser_v":
        return "road_car.glb"
    if vehicle_id.begins_with("carx_") and vehicle_id != "carx_ae86_a" and vehicle_id != "carx_ae86_b":
        return vehicle_id + ".glb"
    return "fleet_" + vehicle_id + ".glb"

static func display_name(vehicle_id: String) -> String:
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
    return {
        "id": resolved,
        "display_name": display_name(resolved),
        "hero_scene": hero_scene(resolved),
    }
