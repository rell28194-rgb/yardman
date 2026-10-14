extends SceneTree

const WarmupScript = preload("res://scripts/shader_warmup.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("SHADER_WARMUP_TEST: " + message)

func _run() -> void:
    var vulkan := WarmupScript.planned_shader_paths("vulkan_mobile")
    var gles := WarmupScript.planned_shader_paths("gles")
    _check(vulkan.size() == 6, "Vulkan warmup does not include both high and thermal-safe material families")
    _check(gles.size() == 3, "GLES warmup should only exercise safe material families")
    var unique := {}
    for path in vulkan:
        unique[path] = true
        _check(ResourceLoader.exists(path), "Warmup resource is missing: %s" % path)
    _check(unique.size() == vulkan.size(), "Vulkan warmup contains duplicate shader paths")

    var warmup = root.get_node_or_null("ShaderWarmup")
    _check(warmup != null, "ShaderWarmup autoload is missing")
    if warmup != null:
        warmup.reset_for_test()
        _check(warmup.begin("vulkan_mobile", true), "Forced headless warmup did not start")
        var started: Dictionary = warmup.debug_snapshot()
        _check(str(started.status) == "warming" and (started.paths as Array).size() == 6, "Warmup runtime did not build the Vulkan variant set")
        for frame in range(8):
            await process_frame
        var completed: Dictionary = warmup.debug_snapshot()
        _check(str(completed.status) == "completed", "Warmup viewport did not complete and release")
        _check(int(completed.frames_remaining) <= 0, "Warmup frame budget did not drain")
    print("YARDMAN_SHADER_WARMUP_TEST %s vulkan_variants=6 gles_variants=3 offscreen_pass=1" % ("PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)
