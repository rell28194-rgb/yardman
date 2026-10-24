extends SceneTree

const Catalog = preload("res://scripts/vehicle_catalog.gd")
const References = preload("res://scripts/reference_assets.gd")
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
    _check(Catalog.hero_scene(Catalog.DEFAULT_ID) == "toyota_crown_2013.glb", "default Crown hero identity drifted")
    _check(Catalog.hero_scene("toyota_chaser") == "road_car.glb", "Chaser hero identity drifted")
    var manifest := References.manifest()
    var available := 0
    var packaged := 0
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
        var packaged_path := References.packaged_scene_path(hero)
        var has_packaged_scene := not packaged_path.is_empty() and ResourceLoader.exists(packaged_path)
        if has_packaged_scene:
            packaged += 1
        if not References.exact_scene_exists(hero):
            _check(false, "%s hero %s has no exact source or packaged scene" % [vehicle_id, hero])
            continue
        available += 1
        var model := FleetModel.new()
        model.call("build", hero)
        _check(not bool(model.get_meta("yardman_hero_asset_missing_or_invalid", false)), "%s failed exact hero load" % vehicle_id)
        _check(bool(model.get_meta("yardman_dedicated_vehicle_mesh", false)), "%s did not mark dedicated geometry" % vehicle_id)
        _check(str(model.get_meta("yardman_requested_hero_scene", "")) == hero, "%s loaded a different hero identity" % vehicle_id)
        _check(bool(model.get("is_reference_model")), "%s is not reference-backed" % vehicle_id)
        var wheels: Array = model.get("wheels")
        var pivots: Array = model.get("front_pivots")
        _check(wheels.size() == 4, "%s wheel spins=%d" % [vehicle_id, wheels.size()])
        _check(pivots.size() == 2, "%s front pivots=%d" % [vehicle_id, pivots.size()])
        model.free()
        built += 1
    _check(packaged == 64, "expected all 64 export-visible packaged scenes, got %d" % packaged)
    print("YARDMAN_OWNER_FLEET_64_PASS selectors=%d available=%d built=%d packaged=%d failures=%d exact_identity=1" % [ids.size(), available, built, packaged, failures])
    quit(0 if failures == 0 else 1)