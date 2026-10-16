extends SceneTree

const Visuals = preload("res://scripts/world_visuals.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error(message)

func _run() -> void:
    var visuals := Visuals.new()
    var terrain_a: ShaderMaterial = visuals.terrain_material(Vector2(16384.0, 4096.0))
    var terrain_b: ShaderMaterial = visuals.terrain_material(Vector2(20480.0, 4096.0))
    _check(terrain_a.get_shader_parameter("tile_origin") == Vector2(16384.0, 4096.0), "Terrain lost its canonical origin")
    _check(terrain_a.get_shader_parameter("surface_noise") == terrain_b.get_shader_parameter("surface_noise"), "Terrain tiles duplicate noise textures")
    var environment := Environment.new()
    var sun := DirectionalLight3D.new()
    visuals.configure_environment(environment, sun)
    visuals.update_daylight(12.0, environment)
    _check(sun.light_energy > 1.0 and environment.ambient_light_energy > 0.6, "Noon lighting is too dark")
    visuals.update_daylight(0.0, environment)
    _check(sun.light_energy < 0.15 and environment.ambient_light_energy < 0.25, "Daylight never transitions to night")
    var segments: Array = []
    for i in range(90):
        var x := 100.0 + float(i % 15) * 60.0
        var z := 100.0 + float(i / 15) * 65.0
        segments.append([x, z, x + 40.0, z, 7.0, 40.0, 0, str(i), "edge", 30.0, 30.0])
    # A crossing road must also exclude vegetation proposed by another road.
    segments.append([250.0, 20.0, 250.0, 700.0, 11.0, 50.0, 0, "cross", "edge", 30.0, 30.0])
    var root := Node3D.new()
    get_root().add_child(root)
    visuals.make_roadside(root, segments, Vector2i.ZERO, 4096.0, func(_x: float, _z: float) -> float: return 31.0)
    var records: Array[Dictionary] = visuals._unique_roads(segments)
    var buckets: Dictionary = visuals._road_buckets(records)
    var roadside := root.get_node("RoadsideProxy") as Node3D
    _check(int(roadside.get_meta("plant_count", 0)) > 10, "Roadside never placed plants")
    for cell: MultiMeshInstance3D in roadside.get_children():
        _check(cell.name != "RoadsideProxy", "Vegetation is still one island-sized culling batch")
        _check(cell.multimesh.mesh.get_surface_count() >= 1, "Vegetation has no mesh")
        _check(cell.multimesh.use_colors, "Compatibility vegetation is missing explicit instance colors")
        for i in range(cell.multimesh.instance_count):
            # The dummy headless renderer does not expose color-buffer reads.
            # The real GL fixture checks their rendered result instead.
            if DisplayServer.get_name() != "headless":
                _check(cell.multimesh.get_instance_color(i) == Color.WHITE, "MultiMesh instance colors darken vegetation")
            var position := cell.position + cell.multimesh.get_instance_transform(i).origin
            _check(absf(position.y - 31.0) < 0.01, "Vegetation ignored terrain height")
            _check(not visuals._inside_road(Vector2(position.x, position.z), buckets, records, 2.5), "Vegetation intersects a neighbouring carriageway")
    visuals.quality = "Custom"
    visuals.custom = {"trees": 99, "shadows": false}
    visuals.apply_roadside_quality(root)
    _check(int(visuals.settings().trees) == 99, "Custom density was overridden")
    for cell: MultiMeshInstance3D in roadside.get_children():
        _check(cell.multimesh.visible_instance_count > 0, "Lower quality removes the visual layer")
        _check(cell.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "Performance shadow choice was ignored")
    root.position += Vector3(100000.0, 0.0, 70000.0)
    _check(terrain_a.get_shader_parameter("tile_origin") == Vector2(16384.0, 4096.0), "Render rebasing moved the terrain texture")
    visuals.make_roadside(root, segments, Vector2i.ZERO, 4096.0, func(_x: float, _z: float) -> float: return NAN)
    _check(int(root.get_node("RoadsideProxy").get_meta("plant_count", 0)) == 0, "Vegetation spawned on missing terrain")
    root.free()
    sun.free()
    if failures == 0:
        print("YARDMAN_VISUALS_TEST PASS materials=1 terrain_placement=1 road_exclusion=1 culling=1 quality=1 daylight=1")
    quit(failures)
