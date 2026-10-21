extends SceneTree

const Runtime = preload("res://scripts/weather_puddle_runtime.gd")

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String, runtime: Node = null) -> void:
    if runtime != null and is_instance_valid(runtime):
        runtime.queue_free()
    push_error("WEATHER_PUDDLE_RUNTIME: " + message)
    await process_frame
    quit(1)

func _run() -> void:
    var records := {
        "way:100:0": {"a": Vector2(-35.0, 0.0), "b": Vector2(35.0, 0.0), "width_m": 8.0, "flags": 0},
        "way:101:0": {"a": Vector2(0.0, -30.0), "b": Vector2(0.0, 30.0), "width_m": 6.0, "flags": 8},
        "way:far:0": {"a": Vector2(200.0, 200.0), "b": Vector2(250.0, 200.0), "width_m": 7.0, "flags": 0},
    }
    var first := Runtime.build_candidates(records, Vector2.ZERO, 85.0, 28)
    var second := Runtime.build_candidates(records, Vector2.ZERO, 85.0, 28)
    if first.is_empty() or first.size() != second.size() or first.size() > 28:
        await _fail("candidate count/determinism contract failed")
        return
    for index in range(first.size()):
        var a: Dictionary = first[index]
        var b: Dictionary = second[index]
        if str(a.identifier) != str(b.identifier) or (a.point as Vector2).distance_to(b.point as Vector2) > 0.000001:
            await _fail("candidate placement is not deterministic")
            return
        var lateral := (a.point as Vector2).distance_to(a.centerline as Vector2)
        if lateral > float(a.half_road_width) + 0.0001:
            await _fail("puddle escaped road width")
            return
        if (a.point as Vector2).length() > 85.0 + float(a.half_road_width):
            await _fail("puddle escaped query radius")
            return
    for candidate: Dictionary in first:
        if str(candidate.identifier).contains("far"):
            await _fail("far road generated a puddle")
            return

    var runtime := Runtime.new()
    root.add_child(runtime)
    await process_frame
    var debug: Dictionary = runtime.debug_state()
    if int(debug.batches) != 1 or int(debug.max_puddles) != 28 or absf(float(debug.query_radius_m) - 85.0) > 0.001:
        await _fail("puddle batch ceiling changed", runtime)
        return
    var batch = runtime.get("_batch") as MultiMeshInstance3D
    if batch == null or batch.multimesh == null or batch.multimesh.instance_count != 28:
        await _fail("preallocated MultiMesh contract failed", runtime)
        return
    if batch.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
        await _fail("puddle shadows must stay disabled", runtime)
        return
    if batch.multimesh.mesh == null or batch.multimesh.mesh.get_surface_count() != 1:
        await _fail("puddles must stay one mesh surface/batch", runtime)
        return
    if int(Runtime.QUALITY_CAPS.Performance) != 6 or int(Runtime.QUALITY_CAPS.Balanced) != 12 \
            or int(Runtime.QUALITY_CAPS.Quality) != 20 or int(Runtime.QUALITY_CAPS.Ultra) != 28:
        await _fail("quality caps changed", runtime)
        return

    print("YARDMAN_WEATHER_PUDDLE_RUNTIME_PASS batches=1 max_puddles=28 radius=85 performance=6 balanced=12 quality=20 ultra=28 collision=off shadows=off reflections=screen_free")
    batch.multimesh = null
    runtime.queue_free()
    for _frame in range(3):
        await process_frame
    quit(0)
