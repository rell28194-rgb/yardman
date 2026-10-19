extends SceneTree

var failures := 0

# Test-only instrumented scheduler: actual inherited _process and arbitration,
# deterministic counters instead of machine-dependent elapsed-time assertions.
class FixtureTerrain:
    extends "res://scripts/terrain_streamer.gd"
    var near_steps := 0
    var far_steps := 0
    var complete_near := false
    var admit_near := false
    func _ready() -> void:
        pass
    func _refresh_tiles(_force: bool) -> void:
        pass
    func _poll_jobs() -> void:
        if admit_near:
            _building = {"fixture": true}
            admit_near = false
    func _start_jobs() -> void:
        pass
    func _prepare_near_geometry() -> void:
        near_steps += 1
        if complete_near:
            _building.clear()
            _loaded["fixture"] = self
    func _prepare_far() -> void:
        far_steps += 1

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("TERRAIN_INTEGRATION_BUDGET_TEST: " + message)

func _run() -> void:
    var terrain := FixtureTerrain.new()
    terrain._far_build = {"fixture": true}
    terrain.admit_near = true
    terrain._process(0.0)
    _check(terrain.near_steps == 1 and terrain.far_steps == 0, "Newly admitted startup terrain did not receive exclusive priority")
    terrain._process(0.0)
    _check(terrain.near_steps == 2 and terrain.far_steps == 0, "Overview consumed a second startup integration slice")
    terrain.complete_near = true
    terrain._process(0.0)
    _check(terrain.near_steps == 3 and terrain.far_steps == 0, "Near publication also ran overview in the same frame")
    terrain.complete_near = false
    terrain.admit_near = true
    for frame in range(8):
        var previous_near := terrain.near_steps
        var previous_far := terrain.far_steps
        terrain._process(0.0)
        _check(terrain.near_steps + terrain.far_steps == previous_near + previous_far + 1, "Both integration lanes consumed a frame")
        _check(terrain.near_steps == previous_near + (1 if frame % 2 == 0 else 0), "Near/far fairness or initial near priority changed")
    _check(terrain.near_steps == 7 and terrain.far_steps == 4, "A continuously pending lane starved")
    terrain._far_build.clear()
    terrain._process(0.0)
    _check(terrain.near_steps == 8 and terrain.far_steps == 4, "Near-only work unnecessarily yielded")
    terrain._building.clear()
    terrain._far_build = {"fixture": true}
    terrain._process(0.0)
    _check(terrain.near_steps == 8 and terrain.far_steps == 5, "Overview-only work stopped progressing")
    # A completed overview worker must enter arbitration even before its
    # payload has been moved into _far_build.
    terrain._far_build.clear()
    terrain._building = {"fixture": true}
    terrain._prefer_far_integration = true
    terrain._far_thread = Thread.new()
    terrain._far_thread.start(func() -> Dictionary: return {"fixture": true})
    while terrain._far_thread.is_alive():
        OS.delay_usec(100)
    terrain._process(0.0)
    _check(terrain.near_steps == 8 and terrain.far_steps == 6, "Completed overview reader was starved behind near work")
    terrain._far_thread.wait_to_finish()
    terrain._far_thread = null
    terrain._building.clear()
    terrain._loaded.clear()
    terrain._far_build.clear()
    terrain.free()
    print("YARDMAN_TERRAIN_INTEGRATION_BUDGET_TEST %s startup_priority=1 one_slice=1 fair_progress=1 poll_admission=1" % ("PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)
