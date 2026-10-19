extends SceneTree

const Registry = preload("res://scripts/render_material_registry.gd")
const Coastline = preload("res://scripts/coastline.gd")

class FakeRoads:
    extends Node3D
    var _asphalt_material := ShaderMaterial.new()
    var _dirt_material := ShaderMaterial.new()
    var surface_visibility_distance := 2600.0

class FakeTerrain:
    extends Node3D
    var _loaded: Dictionary = {}
    var _far_root: Node3D

class FakeScene:
    extends Node3D
    var roads: FakeRoads
    var terrain: FakeTerrain
    var sun: DirectionalLight3D

var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("MATERIAL_VARIANTS_TEST: " + message)

func _run() -> void:
    for family in ["road", "water", "terrain"]:
        var high: Shader = Registry.shader_for(family, "vulkan_mobile", "Quality")
        var safe: Shader = Registry.shader_for(family, "gles", "Quality")
        _check(high != null and safe != null, "%s family did not load both variants" % family)
        _check(high.resource_path != safe.resource_path, "%s high/safe variants still resolve to one shader" % family)
        _check(Registry.variant_name(family, "vulkan_mobile", "Quality") == "%s:high" % family, "%s Vulkan path did not select high shader" % family)
        _check(Registry.variant_name(family, "gles", "Quality") == "%s:safe" % family, "%s GLES path did not select safe shader" % family)
        _check(Registry.variant_name(family, "vulkan_mobile", "Performance") == "%s:safe" % family, "%s Performance tier did not select safe shader" % family)

    var coastline = Coastline.new()
    root.add_child(coastline)
    coastline.apply_render_policy({"quality": "Quality", "water_variant": "depth"}, "vulkan_mobile")
    _check(coastline.water_material.shader.resource_path == "res://shaders/water.gdshader", "Vulkan coastline did not select high water shader")
    coastline.apply_render_policy({"quality": "Quality", "water_variant": "opaque"}, "vulkan_mobile")
    _check(coastline.water_material.shader.resource_path == "res://shaders/water_gles.gdshader", "Thermal/opaque policy did not switch coastline to safe water")
    coastline.apply_render_policy({"quality": "Quality", "water_variant": "depth"}, "gles")
    _check(coastline.water_material.shader.resource_path == "res://shaders/water_gles.gdshader", "GLES coastline escaped safe water path")

    var runtime = root.get_node_or_null("MapQualityBootstrap")
    _check(runtime != null, "MapQualityBootstrap autoload missing")
    if runtime != null:
        var fake := FakeScene.new()
        fake.roads = FakeRoads.new()
        fake.add_child(fake.roads)
        fake.terrain = FakeTerrain.new()
        fake.add_child(fake.terrain)
        fake.roads._asphalt_material.shader = Registry.ROAD_HIGH
        fake.roads._dirt_material.shader = Registry.ROAD_HIGH
        var tile_root := Node3D.new()
        var land := MeshInstance3D.new()
        var plane := PlaneMesh.new()
        var terrain_material := ShaderMaterial.new()
        terrain_material.shader = Registry.TERRAIN_HIGH
        plane.material = terrain_material
        land.mesh = plane
        tile_root.add_child(land)
        fake.terrain._loaded["0:0"] = tile_root
        fake.terrain.add_child(tile_root)
        root.add_child(fake)

        runtime.apply_streamer_material_policy(fake, {
            "renderer": "gles", "quality": "Quality", "road_variant": "safe",
            "terrain_variant": "2layer", "road_visibility": 1800.0,
        })
        _check(fake.roads._asphalt_material.shader.resource_path == "res://shaders/road_surface_gles.gdshader", "Live road asphalt did not switch to safe shader")
        _check(fake.roads._dirt_material.shader.resource_path == "res://shaders/road_surface_gles.gdshader", "Live dirt road did not switch to safe shader")
        _check(is_equal_approx(float(fake.roads._asphalt_material.get_shader_parameter("visibility_distance")), 1800.0), "Road visibility budget was not applied")
        _check(terrain_material.shader.resource_path == "res://shaders/terrain_surface_gles.gdshader", "Loaded terrain material did not switch to safe shader")

        runtime.apply_streamer_material_policy(fake, {
            "renderer": "vulkan_mobile", "quality": "Ultra", "road_variant": "high",
            "terrain_variant": "3layer", "road_visibility": 3200.0,
        })
        _check(fake.roads._asphalt_material.shader.resource_path == "res://shaders/road_surface.gdshader", "Road material did not return to Vulkan high shader")
        _check(terrain_material.shader.resource_path == "res://shaders/terrain_surface.gdshader", "Terrain material did not return to Vulkan high shader")
        fake.queue_free()

    coastline.queue_free()
    await process_frame
    print("YARDMAN_MATERIAL_VARIANTS_TEST %s families=3 runtime_water_switch=1 road_terrain_switch=1" % ("PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)
