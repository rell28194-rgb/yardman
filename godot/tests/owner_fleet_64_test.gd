extends SceneTree

const Catalog = preload("res://scripts/vehicle_catalog.gd")
const References = preload("res://scripts/reference_assets.gd")
const AcceptedModel = preload("res://scripts/vehicle_model.gd")
const FleetModel = preload("res://scripts/fleet_vehicle_model.gd")

var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("OWNER_FLEET_64_TEST: " + message)

func _run() -> void:
    var ids := Catalog.production_ids()
    _check(ids.size() == 64, "expected exactly 64 selectors, got %d" % ids.size())
    _check(not ids.has("toyota_mark_x"), "Mark X must stay excluded")
    _check(not ids.has("port_royal_992"), "992 must stay excluded")
    _check(not ids.has("corvette_c7"), "Corvette remains held")
    _check(not ids.has("delorean_dmc12"), "DeLorean remains held")
    var manifest := References.manifest()
    var available := 0
    var built := 0
    for raw_id in ids:
        var vehicle_id := str(raw_id)
        var hero := Catalog.hero_scene(vehicle_id)
        _check(not hero.is_empty(), "%s has no hero filename" % vehicle_id)
        var matches := 0
        for raw_record in manifest.get("files", []):
            if raw_record is Dictionary and str(raw_record.get("path", "")) == hero:
                matches += 1
        _check(matches == 1, "%s hero %s manifest matches=%d" % [vehicle_id, hero, matches])
        if not ResourceLoader.exists(References.ROOT + hero):
            _check(false, "%s hero %s is not import-resolvable" % [vehicle_id, hero])
            continue
        available += 1
        if vehicle_id == Catalog.DEFAULT_ID:
            var model := AcceptedModel.new()
            model.call("build")
            _check(bool(model.get("is_reference_model")), "Crown accepted reference model did not bind")
            _check(not bool(model.get_meta("yardman_hero_asset_missing_or_invalid", false)), "Crown hero marked invalid")
            model.free()
        else:
            var model := FleetModel.new()
            model.call("build", hero)
            _check(not bool(model.get_meta("yardman_hero_asset_missing_or_invalid", false)), "%s failed exact hero load" % vehicle_id)
            _check(bool(model.get_meta("yardman_dedicated_vehicle_mesh", false)), "%s did not mark dedicated geometry" % vehicle_id)
            _check(bool(model.get("is_reference_model")), "%s is not reference-backed" % vehicle_id)
            var wheels: Array = model.get("wheels")
            var pivots: Array = model.get("front_pivots")
            _check(wheels.size() == 4, "%s wheel spins=%d" % [vehicle_id, wheels.size()])
            _check(pivots.size() == 2, "%s front pivots=%d" % [vehicle_id, pivots.size()])
            model.free()
        built += 1
    print("YARDMAN_OWNER_FLEET_64_PASS selectors=%d available=%d built=%d failures=%d" % [ids.size(), available, built, failures])
    quit(0 if failures == 0 else 1)
