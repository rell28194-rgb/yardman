extends SceneTree

const Catalog = preload("res://scripts/vehicle_catalog.gd")
const References = preload("res://scripts/reference_assets.gd")
const OUTPUT_PATH := "res://data/owner_fleet_runtime_manifest.json"
const EXPECTED_COUNT := 64

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("OWNER_FLEET_EXPORT_MANIFEST: " + message)
    quit(1)

func _run() -> void:
    var ids: Array[String] = Catalog.production_ids()
    if ids.size() != EXPECTED_COUNT:
        _fail("catalog production count is %d, expected %d" % [ids.size(), EXPECTED_COUNT])
        return
    var unique: Dictionary = {}
    var vehicles: Array[Dictionary] = []
    for vehicle_id: String in ids:
        if unique.has(vehicle_id):
            _fail("duplicate production vehicle id: " + vehicle_id)
            return
        unique[vehicle_id] = true
        var hero := Catalog.hero_scene(vehicle_id)
        if hero.is_empty():
            _fail("missing hero mapping for " + vehicle_id)
            return
        var source_path := References.exact_asset_path(hero)
        if source_path.is_empty():
            _fail("missing installed hero source for %s: %s" % [vehicle_id, hero])
            return

        var compiled_path := ""
        var sidecar := "res://assets/user_reference/%s.import" % hero
        if FileAccess.file_exists(sidecar):
            var config := ConfigFile.new()
            var error := config.load(sidecar)
            if error != OK:
                _fail("cannot parse import sidecar for %s: %s" % [vehicle_id, sidecar])
                return
            compiled_path = str(config.get_value("remap", "path", ""))
        if compiled_path.is_empty() and source_path.begins_with("res://.godot/imported/"):
            compiled_path = source_path
        if compiled_path.is_empty() or not compiled_path.begins_with("res://.godot/imported/"):
            _fail("missing compiled import mapping for %s: source=%s compiled=%s" % [vehicle_id, source_path, compiled_path])
            return
        if not ResourceLoader.exists(compiled_path) and not FileAccess.file_exists(compiled_path):
            _fail("compiled resource absent for %s: %s" % [vehicle_id, compiled_path])
            return
        vehicles.append({
            "vehicle_id": vehicle_id,
            "display_name": Catalog.display_name(vehicle_id),
            "hero": hero,
            "source_path": source_path,
            "compiled_resource": compiled_path,
        })

    var payload := {
        "format_version": 1,
        "vehicle_count": vehicles.size(),
        "vehicle_ids": ids,
        "vehicles": vehicles,
        "authority": "vehicle_catalog + private import sidecars after Godot import",
        "cross_model_fallback_allowed": false,
    }
    var absolute := ProjectSettings.globalize_path(OUTPUT_PATH)
    DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
    var file := FileAccess.open(OUTPUT_PATH, FileAccess.WRITE)
    if file == null:
        _fail("cannot write " + OUTPUT_PATH)
        return
    file.store_string(JSON.stringify(payload, "  "))
    file.close()
    print("YARDMAN_OWNER_FLEET_EXPORT_MANIFEST_PASS vehicles=%d compiled=%d" % [vehicles.size(), vehicles.size()])
    quit(0)
