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

class FixtureCorridor:
    extends Node
    var calls := 0
    var last_budget := 0
    var work_remaining := 99
    func advance_terrain_integration(budget_us: int) -> bool:
        calls += 1
        last_budget = budget_us
        work_remaining -= 1
        return work_remaining > 0

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
    _test_corridor_allocation()
    print("YARDMAN_TERRAIN_INTEGRATION_BUDGET_TEST %s startup_priority=1 one_slice=1 fair_progress=1 poll_admission=1 corridor_shared=1" % ("PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)

func _test_corridor_allocation() -> void:
    var terrain := FixtureTerrain.new()
    var corridor := FixtureCorridor.new()
    terrain.geometry_budget_us = 777
    terrain.request_corridor_integration(corridor)
    terrain.request_corridor_integration(corridor)
    _check(terrain._corridor_integrators.size() == 1, "Duplicate notifications created duplicate corridor work")
    terrain._building = {"fixture": true}
    terrain._far_build = {"fixture": true}
    terrain._process(0.0)
    _check(terrain.near_steps == 1 and corridor.calls == 0 and terrain.far_steps == 0,
        "Corridor work stole startup terrain readiness")
    terrain._loaded["fixture"] = terrain
    for frame in range(8):
        var previous_total := terrain.near_steps + terrain.far_steps + corridor.calls
        terrain._process(0.0)
        _check(terrain.near_steps + terrain.far_steps + corridor.calls == previous_total + 1,
            "Terrain and corridor consumed separate allocations in one frame")
    _check(terrain.near_steps == 3 and terrain.far_steps == 2 and corridor.calls == 4,
        "Pending near/far/corridor lanes did not all progress")
    _check(corridor.last_budget == 777, "Corridor created an independent budget")
    terrain.cancel_corridor_integration(corridor)
    terrain._process(0.0)
    _check(corridor.calls == 4, "Cancelled participant was advanced")
    terrain.request_corridor_integration(corridor)
    corridor.free()
    terrain._process(0.0)
    _check(terrain._corridor_integrators.is_empty(), "Freed participant was retained or called")
    terrain._building.clear()
    terrain._far_build.clear()
    var first := FixtureCorridor.new()
    var second := FixtureCorridor.new()
    first.work_remaining = 2
    second.work_remaining = 2
    terrain.request_corridor_integration(first)
    terrain.request_corridor_integration(second)
    for frame in range(4):
        terrain._process(0.0)
    _check(first.calls == 2 and second.calls == 2 and terrain._corridor_integrators.is_empty(),
        "Corridor participants starved or remained registered after completion")
    first.free()
    second.free()
    terrain._loaded.clear()
    terrain.free()
