extends SceneTree

const Traffic = preload("res://scripts/traffic_runtime.gd")
const Pedestrians = preload("res://scripts/pedestrian_runtime.gd")
var failures := 0

class SceneFixture extends Node:
    var day_hour := 13.0

class RoadsFixture extends RefCounted:
    func _nearby_surface_segments(_x: float, _z: float, _radius: float) -> Dictionary:
        return {}

func _init() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("POPULATION_BUDGET_REGRESSION: " + message)

func _reconcile(runtime, scene: Node, roads, traffic: bool) -> void:
    if traffic:
        runtime._reconcile_population(scene, roads, null, Vector2.ZERO)
    else:
        runtime._reconcile_population(scene, roads, Vector2.ZERO)

func _exercise(runtime, traffic: bool) -> void:
    var label := "traffic" if traffic else "pedestrians"
    var scene := SceneFixture.new()
    scene.day_hour = 8.0 if traffic else 13.0
    var roads := RoadsFixture.new()
    runtime.apply_render_policy({"quality": "Ultra", "thermal_stage": 0})
    var initial_count: int = runtime.max_agents
    var retired_nodes: Array[Node] = []
    # Insert in reverse order so the survivors cannot depend on insertion order.
    # All actors stay inside the new despawn radius: only budget contraction can
    # retire them, reproducing stationary-player thermal and time-of-day changes.
    for index in range(initial_count - 1, -1, -1):
        var identifier := "actor_%02d" % index
        var body := Node3D.new()
        scene.add_child(body)
        retired_nodes.append(body)
        runtime.agents[identifier] = {"position": Vector2(20.0 + index, 0), "node": body}
    runtime.apply_render_policy({"quality": "Performance", "thermal_stage": 5})
    _reconcile(runtime, scene, roads, traffic)
    var minimum := 4 if traffic else 3
    var expected := clampi(int(round(float(runtime.max_agents) * runtime.density_for_hour(scene.day_hour))), minimum, int(runtime.max_agents))
    _check(runtime.agents.size() == expected, label + " did not contract after thermal policy reduction")
    _check(runtime.agents.has("actor_00"), label + " removed the closest actor")
    _check(not runtime.agents.has("actor_%02d" % (initial_count - 1)), label + " retained the farthest actor")
    _check(retired_nodes[0].is_queued_for_deletion(), label + " leaked retired actor's scene node")
    _check(not retired_nodes[-1].is_queued_for_deletion(), label + " freed a retained actor's scene node")
    scene.day_hour = 3.0
    runtime._weather_density_factor = runtime.weather_density_factor(1.0)
    _reconcile(runtime, scene, roads, traffic)
    expected = clampi(int(round(float(runtime.max_agents) * runtime.density_for_hour(scene.day_hour) * runtime._weather_density_factor)), minimum, int(runtime.max_agents))
    _check(runtime.agents.size() == expected, label + " ignored overnight/storm density reduction")
    var survivors: Array = runtime.agents.keys()
    _reconcile(runtime, scene, roads, traffic)
    _check(runtime.agents.keys() == survivors, label + " churned population at a stable budget")
    var expected_far: int = maxi(0, runtime.statistical_population_for(runtime.max_agents, scene.day_hour, runtime._weather_density_factor) - expected)
    _check(runtime.runtime_snapshot().far_statistical == expected_far, label + " reported stale far population")
    runtime._clear_scene_state()
    # Equal-distance tie-breaking is deterministic even across spawn order.
    runtime.agents = {"z": {"position": Vector2(30, 0)}, "a": {"position": Vector2(-30, 0)}}
    runtime._trim_population(1, Vector2.ZERO)
    _check(runtime.agents.has("a") and runtime.agents.size() == 1, label + " distance tie was unstable")
    runtime._trim_population(0, Vector2.ZERO)
    _check(runtime.agents.is_empty(), label + " zero-budget trim retained actors")
    runtime.free()
    scene.free()

func _exercise_visual_priority(runtime, label: String) -> void:
    # Identifier order deliberately disagrees with distance order. Expensive
    # near visual slots must follow player distance with deterministic ties.
    runtime.agents = {
        "a_far": {"position": Vector2(120, 0)},
        "m_mid": {"position": Vector2(55, 0)},
        "z_near": {"position": Vector2(8, 0)},
    }
    var ranked: Array = runtime._visual_priority_ids(Vector2.ZERO)
    _check(ranked == ["z_near", "m_mid", "a_far"], label + " near visual priority ignored distance")
    runtime.agents = {
        "z_tie": {"position": Vector2(30, 0)},
        "a_tie": {"position": Vector2(-30, 0)},
    }
    ranked = runtime._visual_priority_ids(Vector2.ZERO)
    _check(ranked == ["a_tie", "z_tie"], label + " near visual distance tie was unstable")
    runtime.agents.clear()
    runtime.free()

func _run() -> void:
    _exercise(Traffic.new(), true)
    _exercise(Pedestrians.new(), false)
    _exercise_visual_priority(Traffic.new(), "traffic")
    _exercise_visual_priority(Pedestrians.new(), "pedestrians")
    if failures == 0:
        print("YARDMAN_POPULATION_BUDGET_REGRESSION PASS thermal=2 density=2 lifecycle=4 stable=2 far=2 ties=2 zero=2 visual_priority=4")
    else:
        print("YARDMAN_POPULATION_BUDGET_REGRESSION FAIL failures=%d" % failures)
    quit(0 if failures == 0 else 1)
