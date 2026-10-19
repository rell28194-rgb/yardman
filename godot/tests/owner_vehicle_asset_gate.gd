extends SceneTree

const Catalog = preload("res://scripts/vehicle_catalog.gd")
const References = preload("res://scripts/reference_assets.gd")

var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("OWNER_VEHICLE_ASSET_GATE: " + message)

func _run() -> void:
    var roster := Catalog.production_ids()
    _check(roster.size() == 64, "owner roster is not exactly 64 selectors: %d" % roster.size())
    _check(not roster.has("toyota_mark_x"), "scrapped Mark X leaked into owner roster")
    _check(not roster.has("port_royal_992"), "scrapped 992 leaked into owner roster")
    _check(not roster.has("corvette_c7"), "held C7 leaked into owner roster")
    _check(not roster.has("delorean_dmc12"), "held DeLorean leaked into owner roster")

    var seen_heroes: Dictionary = {}
    var verified := 0
    for vehicle_id_variant in roster:
        var vehicle_id := str(vehicle_id_variant)
        var profile := Catalog.profile(vehicle_id)
        _check(str(profile.get("id", "")) == vehicle_id, "%s profile identity mismatch" % vehicle_id)
        var hero := str(profile.get("hero_scene", ""))
        _check(not hero.is_empty(), "%s has no dedicated hero binding" % vehicle_id)
        if hero.is_empty():
            continue
        _check(not seen_heroes.has(hero), "%s shares hero media with %s: %s" % [vehicle_id, str(seen_heroes.get(hero, "")), hero])
        seen_heroes[hero] = vehicle_id
        var scene := References.scene(hero)
        _check(scene != null, "%s dedicated hero is absent, invalid, or not manifest-verified: %s" % [vehicle_id, hero])
        if scene != null:
            verified += 1

    _check(verified == 64, "only %d/64 owner heroes passed manifest verification" % verified)
    print("YARDMAN_OWNER_VEHICLE_ASSET_GATE_%s selectors=%d verified_heroes=%d" % [
        "PASS" if failures == 0 else "FAIL", roster.size(), verified
    ])
    quit(failures)
