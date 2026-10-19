extends SceneTree

const Catalog = preload("res://scripts/vehicle_catalog.gd")
const Controller = preload("res://scripts/vehicle_controller.gd")
const References = preload("res://scripts/reference_assets.gd")

var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("CLEAN_VEHICLE_INTEGRATION: " + message)

func _run() -> void:
    _check(Catalog.DEFAULT_ID == "toyota_crown", "Crown is not the reset default")
    _check(not Catalog.has("toyota_mark_x"), "scrapped Mark X is selectable")
    _check(not Catalog.has("port_royal_992"), "scrapped 992 is selectable")
    _check(not Catalog.has("corvette_c7"), "held C7 is selectable without owner hero media")
    _check(not Catalog.has("delorean_dmc12"), "held DeLorean is selectable without owner hero media")
    var roster := Catalog.production_ids()
    _check(roster.size() == 64, "owner production roster must contain exactly 64 selectors, got %d" % roster.size())
    _check(roster.has("toyota_crown"), "Crown owner selector missing")
    _check(roster.has("audi_r8"), "Audi R8 recovered selector missing")
    _check(roster.has("bmw_m3_e46"), "BMW M3 E46 recovered selector missing")
    _check(roster.has("mazda_rx7"), "Mazda RX-7 recovered selector missing")
    _check(roster.has("nissan_skyline_r34"), "Skyline R34 recovered selector missing")
    _check(roster.has("toyota_supra_rz"), "Supra RZ recovered selector missing")

    var body := CharacterBody3D.new()
    root.add_child(body)
    var controller = Controller.new()
    controller.configure(body)
    _check(controller.vehicle_id == "toyota_crown", "controller did not boot as Crown")
    _check(controller.profile_metadata().get("hero_scene", "") == "toyota_crown_2013.glb", "Crown hero identity lost")

    var private_crown := References.scene("toyota_crown_2013.glb") != null
    if private_crown:
        _check(bool(controller.visual.get_meta("yardman_dedicated_vehicle_mesh", false)), "private Crown exists but was not used")
        _check(not bool(controller.visual.get_meta("yardman_procedural_vehicle_fallback", false)), "private Crown fell back procedurally")

    controller.apply_profile("nissan_skyline_r34")
    _check(controller.vehicle_id == "nissan_skyline_r34", "recovered fleet selector cannot reach controller")
    _check(controller.profile_metadata().get("hero_scene", "") == "fleet_nissan_skyline_r34.glb", "recovered hero binding lost")

    body.queue_free()
    print("YARDMAN_CLEAN_VEHICLE_INTEGRATION_%s roster=%d private_crown=%s" % ["PASS" if failures == 0 else "FAIL", roster.size(), str(private_crown)])
    quit(failures)
