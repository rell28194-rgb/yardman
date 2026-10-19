extends SceneTree

const Catalog = preload("res://scripts/vehicle_catalog.gd")
const References = preload("res://scripts/reference_assets.gd")
const CONTRACT_PATH := "res://data/owner_fleet_pack_contract.json"

var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    failures += 1
    push_error("OWNER_VEHICLE_ASSET_GATE: " + message)

func _sorted_strings(values: Array) -> Array[String]:
    var result: Array[String] = []
    for value in values:
        result.append(str(value))
    result.sort()
    return result

func _run() -> void:
    if not FileAccess.file_exists(CONTRACT_PATH):
        _fail("owner fleet contract is missing")
        quit(1)
        return
    var parsed = JSON.parse_string(FileAccess.get_file_as_string(CONTRACT_PATH))
    if not parsed is Dictionary or int(parsed.get("format_version", 0)) != 1:
        _fail("owner fleet contract is invalid")
        quit(1)
        return
    var contract: Dictionary = parsed
    var ids: Array = Catalog.production_ids()
    var expected_ids: Array = contract.get("available_vehicle_ids", [])
    if _sorted_strings(ids) != _sorted_strings(expected_ids):
        _fail("production selector set does not match the authoritative 64-car owner pack")
    if ids.size() != int(contract.get("available_vehicle_count", -1)):
        _fail("production selector count drifted from owner fleet contract")
    for raw_id in contract.get("scrapped_vehicle_ids", []):
        if ids.has(str(raw_id)):
            _fail("scrapped vehicle re-entered production fleet: %s" % str(raw_id))
    for raw_id in contract.get("held_missing_vehicle_ids", []):
        if ids.has(str(raw_id)):
            _fail("held vehicle without owner hero media became selectable: %s" % str(raw_id))

    var missing: Array[String] = []
    var invalid: Array[String] = []
    for raw_id in ids:
        var vehicle_id := str(raw_id)
        var profile: Dictionary = Catalog.profile(vehicle_id)
        var hero := str(profile.get("hero_scene", ""))
        if hero.is_empty():
            invalid.append(vehicle_id + ":no-hero-scene")
            continue
        var path := References.ROOT + hero
        if not ResourceLoader.exists(path):
            missing.append(vehicle_id + ":" + hero)
            continue
        if References.scene(hero) == null:
            invalid.append(vehicle_id + ":" + hero)

    if not missing.is_empty():
        _fail("missing dedicated owner hero assets: %s" % ", ".join(missing))
    if not invalid.is_empty():
        _fail("invalid/unverified dedicated owner hero assets: %s" % ", ".join(invalid))

    print("YARDMAN_OWNER_VEHICLE_ASSET_GATE %s vehicles=%d expected=%d missing=%d invalid=%d" % [
        "PASS" if failures == 0 else "FAIL", ids.size(), int(contract.get("available_vehicle_count", 0)), missing.size(), invalid.size()])
    quit(0 if failures == 0 else 1)
