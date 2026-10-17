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
    var car := scene.get_node_or_null("RoadQA") as CharacterBody3D
    var vehicle = scene.get("vehicle")
    if vehicle == null or str(vehicle.get("performance_profile")) != "crown_stage3_compound_hybrid":
        _fail("Crown Stage 3 compound-hybrid profile is not active at boot")
        return
    var performance = vehicle.call("performance_state")
    if not performance is Dictionary or absf(float(performance.get("top_speed_kmh", 0.0)) - 378.0) > 0.1:
        _fail("Crown Stage 3 limiter contract is not 378 km/h")
        return
    for frame in range(1800):
        await physics_frame
        # A newly streamed collision tile is ready before gravity has settled
        # the spawned car onto it. Finish on actual grounded boot, not that
        # earlier streaming signal, or exporter performance changes race CI.
        if frame >= 60 and roads != null and scene.get("world_ready") \
                and car != null and car.is_on_floor():
            break
    if car == null or roads == null:
        _fail("Vehicle or road streamer is absent after boot")
        return
    if not car.global_position.is_finite() or car.global_position.y < -2.0:
        _fail("Vehicle did not remain on the driving surface")
        return
    var terrain := scene.get_node_or_null("JamaicaTerrainStreamer")
    if terrain == null or not scene.world_ready or not car.is_on_floor():
        _fail("Real terrain did not become ready or the vehicle did not settle")
        return
    var loaded = roads.get("_loaded")
    if not loaded is Dictionary or loaded.is_empty():
        _fail("No real road tiles were instantiated near the spawn")
        return
    print("YARDMAN_SMOKE_PASS loaded_tiles=%d vehicle_y=%.3f crown_stage3=1 top_speed_kmh=%.1f" % [loaded.size(), car.global_position.y, float(performance.top_speed_kmh)])
    scene.queue_free()
    await process_frame
    quit(0)

func _fail(message: String) -> void:
    push_error("YARDMAN_SMOKE_FAIL: " + message)
    quit(1)
