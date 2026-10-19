extends SceneTree

const Catalog = preload("res://scripts/vehicle_catalog.gd")
const References = preload("res://scripts/reference_assets.gd")

var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    failures += 1
    push_error("OWNER_VEHICLE_ASSET_GATE: " + message)

func _run() -> void:
    var ids: Array = Catalog.production_ids()
    if ids.size() < 2:
        _fail("production fleet collapsed to fewer than two vehicles")
    if ids.has("toyota_mark_x"):
        _fail("banned Toyota Mark X re-entered production fleet")
    if ids.has("port_royal_992"):
        _fail("banned 992 path re-entered production fleet")

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

    print("YARDMAN_OWNER_VEHICLE_ASSET_GATE %s vehicles=%d missing=%d invalid=%d" % [
        "PASS" if failures == 0 else "FAIL", ids.size(), missing.size(), invalid.size()])
    quit(0 if failures == 0 else 1)
