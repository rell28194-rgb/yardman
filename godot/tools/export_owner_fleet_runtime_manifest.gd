extends SceneTree

const Catalog = preload("res://scripts/vehicle_catalog.gd")
const References = preload("res://scripts/reference_assets.gd")
const OUTPUT_PATH := "res://data/owner_fleet_runtime_manifest.json"
const EXPECTED_COUNT := 64
const SAVE_FLAGS := ResourceSaver.FLAG_BUNDLE_RESOURCES | ResourceSaver.FLAG_COMPRESS | ResourceSaver.FLAG_OMIT_EDITOR_PROPERTIES

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
    var packaged_root := ProjectSettings.globalize_path(References.PACKAGED_SCENE_ROOT)
    if DirAccess.make_dir_recursive_absolute(packaged_root) != OK:
        _fail("cannot create export-visible fleet scene directory: " + References.PACKAGED_SCENE_ROOT)
        return

    var unique: Dictionary = {}
    var vehicles: Array[Dictionary] = []
    var packaged_count := 0
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

        var imported_path := ""
        var sidecar := "res://assets/user_reference/%s.import" % hero
        if FileAccess.file_exists(sidecar):
            var config := ConfigFile.new()
            var error := config.load(sidecar)
            if error != OK:
                _fail("cannot parse import sidecar for %s: %s" % [vehicle_id, sidecar])
                return
            imported_path = str(config.get_value("remap", "path", ""))
        if imported_path.is_empty() and source_path.begins_with("res://.godot/imported/"):
            imported_path = source_path
        if imported_path.is_empty() or not imported_path.begins_with("res://.godot/imported/"):
            _fail("missing compiled import mapping for %s: source=%s compiled=%s" % [vehicle_id, source_path, imported_path])
            return
        if not ResourceLoader.exists(imported_path) and not FileAccess.file_exists(imported_path):
            _fail("compiled resource absent for %s: %s" % [vehicle_id, imported_path])
            return

        var imported := ResourceLoader.load(imported_path) as PackedScene
        if imported == null:
            _fail("compiled resource is not a PackedScene for %s: %s" % [vehicle_id, imported_path])
            return
        var packaged_path := References.packaged_scene_path(hero)
        if packaged_path.is_empty():
            _fail("invalid export-visible scene path for %s: %s" % [vehicle_id, hero])
            return
        var save_error := ResourceSaver.save(imported, packaged_path, SAVE_FLAGS)
        if save_error != OK:
            _fail("cannot bundle export-visible scene for %s: %s error=%d" % [vehicle_id, packaged_path, save_error])
            return
        if not FileAccess.file_exists(packaged_path):
            _fail("bundled scene was not written for %s: %s" % [vehicle_id, packaged_path])
            return

        var reloaded := ResourceLoader.load(packaged_path, "", ResourceLoader.CACHE_MODE_REPLACE) as PackedScene
        if reloaded == null:
            _fail("bundled scene cannot reload for %s: %s" % [vehicle_id, packaged_path])
            return
        var instance = reloaded.instantiate()
        if not instance is Node3D:
            if instance != null:
                instance.free()
            _fail("bundled scene does not instantiate as Node3D for %s: %s" % [vehicle_id, packaged_path])
            return
        instance.free()
        packaged_count += 1

        vehicles.append({
            "vehicle_id": vehicle_id,
            "display_name": Catalog.display_name(vehicle_id),
            "hero": hero,
            "source_path": source_path,
            "source_compiled_resource": imported_path,
            "compiled_resource": packaged_path,
        })

    var payload := {
        "format_version": 1,
        "vehicle_count": vehicles.size(),
        "vehicle_ids": ids,
        "vehicles": vehicles,
        "authority": "vehicle_catalog + private import sidecars + bundled export-visible PackedScenes",
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
    print("YARDMAN_OWNER_FLEET_EXPORT_MANIFEST_PASS vehicles=%d compiled=%d packaged=%d" % [vehicles.size(), vehicles.size(), packaged_count])
    quit(0)
