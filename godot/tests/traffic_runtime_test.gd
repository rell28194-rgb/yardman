extends SceneTree

const Traffic = preload("res://scripts/traffic_runtime.gd")
var failures := 0

func _init() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if condition:
        return
    failures += 1
    push_error("TRAFFIC_RUNTIME_TEST: " + message)

func _agent(identifier: String, record: Dictionary, direction: int, progress: float) -> Dictionary:
    var pose := Traffic.lane_pose(record, progress, direction)
    return {
        "id": identifier,
        "record": record,
        "direction": direction,
        "progress": progress,
        "position": Vector2(pose.position),
        "speed": 6.0,
        "target_speed": 10.0,
    }

func _run() -> void:
    var arterial := {"a": Vector2(0, 0), "b": Vector2(100, 0), "width_m": 10.0, "class_id": 1, "edge_id": "arterial"}
    var forward := Traffic.lane_pose(arterial, 0.5, 1)
    var reverse := Traffic.lane_pose(arterial, 0.5, -1)
    _check(not forward.is_empty() and not reverse.is_empty(), "lane pose failed")
    _check(absf(float(forward.position.x) - 50.0) < 0.001, "forward progress left source centreline station")
    _check(Vector2(forward.position).y * Vector2(reverse.position).y < 0.0, "opposing Jamaica lanes should occupy opposite carriageway sides")
    _check(Vector2(forward.travel).dot(Vector2(reverse.travel)) < -0.99, "opposing travel headings are not opposite")

    var next_forward := {"a": Vector2(100, 0), "b": Vector2(180, 5), "width_m": 8.0, "class_id": 1, "edge_id": "next"}
    var turn_south := {"a": Vector2(100, 0), "b": Vector2(100, 80), "width_m": 6.0, "class_id": 5, "edge_id": "south"}
    var uturn := {"a": Vector2(100, 0), "b": Vector2(40, 0), "width_m": 8.0, "class_id": 2, "edge_id": "uturn"}
    var disconnected := {"a": Vector2(130, 80), "b": Vector2(180, 80), "width_m": 8.0, "class_id": 2, "edge_id": "far"}
    var candidates := {"next": next_forward, "south": turn_south, "uturn": uturn, "far": disconnected}
    var continuation := Traffic.continuation_for(arterial, 1, candidates)
    _check(not continuation.is_empty(), "connected continuation not found")
    _check(str(continuation.record.edge_id) == "next", "route continuation selected U-turn or disconnected road")
    _check(int(continuation.direction) == 1, "continuation direction incorrect")
    var options := Traffic.junction_options(arterial, 1, candidates)
    _check(options.size() == 2, "junction did not expose straight and turning options")

    var side_road := {"a": Vector2(100, -70), "b": Vector2(100, 0), "width_m": 5.5, "class_id": 5, "edge_id": "side"}
    var endpoint := Vector2(100, 0)
    var population := {
        "main": _agent("main", arterial, 1, 0.92),
        "side": _agent("side", side_road, 1, 0.92),
    }
    _check(Traffic.road_priority(arterial) > Traffic.road_priority(side_road), "road hierarchy did not prioritize the arterial")
    _check(Traffic.should_yield_at_junction("side", side_road, 1, endpoint, population), "side-road traffic failed to yield to higher-priority arterial traffic")
    _check(not Traffic.should_yield_at_junction("main", arterial, 1, endpoint, population), "arterial traffic yielded to lower-priority side road")

    var equal_a := {"a": Vector2(100, -70), "b": Vector2(100, 0), "width_m": 6.0, "class_id": 3, "edge_id": "equal-a"}
    var equal_b := {"a": Vector2(170, 0), "b": Vector2(100, 0), "width_m": 6.0, "class_id": 3, "edge_id": "equal-b"}
    var equal_population := {
        "a": _agent("a", equal_a, 1, 0.92),
        "b": _agent("b", equal_b, 1, 0.92),
    }
    _check(Traffic.should_yield_at_junction("b", equal_b, 1, endpoint, equal_population), "equal-priority conflict lacked deterministic tie break")
    _check(not Traffic.should_yield_at_junction("a", equal_a, 1, endpoint, equal_population), "deterministic junction winner also yielded")

    _check(Traffic.density_for_hour(8.0) > Traffic.density_for_hour(3.0), "morning traffic should exceed overnight density")
    _check(Traffic.density_for_hour(17.0) > Traffic.density_for_hour(12.0), "evening peak should exceed midday density")

    var balanced := Traffic.budget_for("Balanced", 0)
    var hot := Traffic.budget_for("Balanced", 5)
    var performance := Traffic.budget_for("Performance", 0)
    _check(int(hot.max_agents) < int(balanced.max_agents), "thermal traffic budget did not degrade")
    _check(int(hot.near_visuals) <= int(balanced.near_visuals), "thermal near-vehicle budget did not degrade")
    _check(int(performance.max_agents) < int(balanced.max_agents), "Performance traffic budget should be smaller")
    _check(float(hot.near_radius) >= 120.0 and float(hot.medium_radius) >= 320.0, "thermal policy erased required near/medium simulation coverage")

    if failures == 0:
        print("YARDMAN_TRAFFIC_RUNTIME_TEST PASS lanes=2 continuation=1 junction_yield=4 density_cycle=1 simulation_lod=3")
        quit()
    else:
        print("YARDMAN_TRAFFIC_RUNTIME_TEST FAIL failures=%d" % failures)
        quit(1)
