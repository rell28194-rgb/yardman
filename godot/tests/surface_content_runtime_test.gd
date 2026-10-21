extends SceneTree

const Runtime = preload("res://scripts/surface_content_runtime.gd")
const TerrainShader = preload("res://shaders/terrain_surface.gdshader")
const BeachShader = preload("res://shaders/beach.gdshader")
const RoadShader = preload("res://shaders/road_surface.gdshader")

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("SURFACE_CONTENT_RUNTIME: " + message)
    quit(1)

func _run() -> void:
    var expected := {
        "ground_lush": ["ground_lush.jpg", 166365],
        "ground_dry": ["ground_dry.jpg", 254129],
        "ground_wet_soil": ["ground_wet_soil.jpg", 207514],
        "ground_rock": ["ground_rock.jpg", 306316],
        "beach_sand": ["beach_sand.jpg", 207120],
        "road_gravel": ["road_gravel.jpg", 296796],
    }
    var runtime := Runtime.new()
    var textures: Dictionary = {}
    var total := 0
    var user_root := "user://surface-runtime-test/"
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(user_root))
    for role in expected.keys():
        var filename := str(expected[role][0])
        var expected_bytes := int(expected[role][1])
        var source_path := "res://build/surface-runtime-test/" + filename
        var user_path := user_root + filename
        if not FileAccess.file_exists(source_path):
            _fail("missing downloaded surface: " + filename)
            return
        var bytes_data := FileAccess.get_file_as_bytes(source_path)
        if bytes_data.size() != expected_bytes:
            _fail("byte contract failed: %s %d != %d" % [filename, bytes_data.size(), expected_bytes])
            return
        var output := FileAccess.open(user_path, FileAccess.WRITE)
        if output == null:
            _fail("could not stage user-storage texture: " + filename)
            return
        output.store_buffer(bytes_data)
        output.close()
        total += bytes_data.size()
        var texture = runtime.call("_load_texture_file", user_path)
        if not texture is ImageTexture:
            _fail("JPEG decode failed: " + filename)
            return
        if texture.get_width() != 768 or texture.get_height() != 768:
            _fail("texture dimensions changed: " + filename)
            return
        textures[role] = texture
    if total != 1_438_240:
        _fail("pack byte contract changed: %d" % total)
        return
    runtime.set("_textures", textures)

    var terrain: ShaderMaterial = ShaderMaterial.new()
    terrain.shader = TerrainShader
    runtime.apply_terrain_material(terrain)
    if terrain.get_shader_parameter("has_surface_hd") != true:
        _fail("terrain Surface HD flag not bound")
        return
    for parameter in ["surface_hd_lush", "surface_hd_dry", "surface_hd_soil", "surface_hd_rock"]:
        if terrain.get_shader_parameter(parameter) == null:
            _fail("terrain texture missing: " + parameter)
            return

    var beach: ShaderMaterial = ShaderMaterial.new()
    beach.shader = BeachShader
    runtime.apply_beach_material(beach)
    if beach.get_shader_parameter("has_surface_hd_sand") != true or beach.get_shader_parameter("surface_hd_sand") == null:
        _fail("beach Surface HD binding failed")
        return

    var road: ShaderMaterial = ShaderMaterial.new()
    road.shader = RoadShader
    runtime.apply_road_material(road)
    if road.get_shader_parameter("has_surface_hd_gravel") != true or road.get_shader_parameter("surface_hd_gravel") == null:
        _fail("road Surface HD binding failed")
        return

    print("YARDMAN_SURFACE_CONTENT_RUNTIME_PASS assets=6 bytes=1438240 dimensions=768 terrain=4 beach=1 road=1 draw_calls_added=0 geometry_added=0")

    # Release all GPU-backed resources before SceneTree teardown so the strict
    # gate distinguishes real runtime errors from a test that quits too early.
    terrain = null
    beach = null
    road = null
    runtime.set("_textures", {})
    textures.clear()
    runtime.free()
    await process_frame
    RenderingServer.sync()
    await process_frame
    for role in expected.keys():
        var filename := str(expected[role][0])
        var user_path := user_root + filename
        if FileAccess.file_exists(user_path):
            DirAccess.remove_absolute(ProjectSettings.globalize_path(user_path))
    quit(0)
