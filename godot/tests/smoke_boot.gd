extends SceneTree

func _initialize() -> void:
    call_deferred("_run")

func _run() -> void:
    if not ProjectSettings.get_setting("rendering/textures/vram_compression/import_etc2_astc", false):
        _fail("Android texture compression is disabled")
        return
    if not FileAccess.file_exists("res://data/roads/manifest.json"):
        _fail("The national road dataset must exist before boot validation")
        return
    var packed := load("res://main.tscn") as PackedScene
    if packed == null:
        _fail("Main scene failed to load")
        return
    var scene := packed.instantiate()
    root.add_child(scene)
    var roads := scene.get_node_or_null("JamaicaRoadStreamer")
    for frame in range(600):
        await physics_frame
        if frame >= 60 and roads != null and roads.is_tile_ready(Vector2i.ZERO):
            break
    var car := scene.get_node_or_null("RoadQA") as CharacterBody3D
    if car == null or roads == null:
        _fail("Vehicle or road streamer is absent after boot")
        return
    if not car.global_position.is_finite() or car.global_position.y < -2.0:
        _fail("Vehicle did not remain on the driving surface")
        return
    var loaded = roads.get("_loaded")
    if not loaded is Dictionary or loaded.is_empty():
        _fail("No real road tiles were instantiated near the spawn")
        return
    print("YARDMAN_SMOKE_PASS loaded_tiles=%d vehicle_y=%.3f" % [loaded.size(), car.global_position.y])
    scene.queue_free()
    await process_frame
    quit(0)

func _fail(message: String) -> void:
    push_error("YARDMAN_SMOKE_FAIL: " + message)
    quit(1)
