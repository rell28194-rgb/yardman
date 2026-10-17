extends SceneTree

# Sustained traversal soak. Visits every parish repeatedly (each visit unloads
# and reloads the terrain, road, building and coast rings and rebases the
# origin) and checks that node, object and memory counts stop growing once the
# first lap has warmed the caches. It is a headless leak/residency guard, not a
# frame-time, GPU or thermal benchmark: those still need a real device.

const LAPS := 5
const FRAMES_PER_STOP := 40
const MAX_NODE_GROWTH := 0.03       # fraction of the post-warm-up node count
const MAX_OBJECT_GROWTH := 0.05     # fraction of the post-warm-up object count
const MAX_STATIC_GROWTH_MB := 64.0  # allowance for allocator slack

var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("SOAK_TEST: " + message)

func _wait_ready(scene) -> void:
    for frame in range(1800):
        await physics_frame
        var body: CharacterBody3D = scene.car if scene.player.in_vehicle else scene.player
        if scene.world_ready and body.is_on_floor():
            return
    _check(false, "World did not become ready in " + scene.current_parish)

func _sample() -> Dictionary:
    return {
        "nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
        "objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
        "orphans": int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
        "static_mb": float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0,
    }

func _lap(scene) -> Dictionary:
    var peak_terrain := 0
    for parish in scene.roads.manifest.parish_anchors:
        scene.goto_parish(str(parish))
        await _wait_ready(scene)
        for frame in range(FRAMES_PER_STOP):
            await physics_frame
        peak_terrain = maxi(peak_terrain, scene.terrain._loaded.size())
        _check(scene.car.position.length() < 3000.0, "Car drifted from the local origin in " + str(parish))
    var sample := _sample()
    sample["peak_terrain"] = peak_terrain
    return sample

func _run() -> void:
    var scene = load("res://main.tscn").instantiate()
    root.add_child(scene)
    await _wait_ready(scene)
    var warm: Dictionary = await _lap(scene)
    print("SOAK warm-up   %s" % [warm])
    var last := warm
    for lap in range(1, LAPS):
        last = await _lap(scene)
        print("SOAK lap %d     %s" % [lap, last])
        _check(int(last.peak_terrain) <= 25, "Terrain residency exceeded its bounded ring on lap %d" % lap)
    var node_growth := float(int(last.nodes) - int(warm.nodes)) / maxf(1.0, float(warm.nodes))
    var object_growth := float(int(last.objects) - int(warm.objects)) / maxf(1.0, float(warm.objects))
    var static_growth := float(last.static_mb) - float(warm.static_mb)
    _check(node_growth <= MAX_NODE_GROWTH, "Node count grew %.1f%% across %d laps" % [node_growth * 100.0, LAPS - 1])
    _check(object_growth <= MAX_OBJECT_GROWTH, "Object count grew %.1f%% across %d laps" % [object_growth * 100.0, LAPS - 1])
    _check(static_growth <= MAX_STATIC_GROWTH_MB, "Static memory grew %.1f MB across %d laps" % [static_growth, LAPS - 1])
    _check(int(last.orphans) <= int(warm.orphans), "Orphan nodes accumulated: %d -> %d" % [int(warm.orphans), int(last.orphans)])
    print("YARDMAN_SOAK_TEST %s laps=%d node_growth=%.2f%% object_growth=%.2f%% static_growth_mb=%.1f" % [
        "PASS" if failures == 0 else "FAIL", LAPS, node_growth * 100.0, object_growth * 100.0, static_growth])
    scene.queue_free()
    await process_frame
    quit(0 if failures == 0 else 1)
