extends SceneTree

const RoadGraph = preload("res://scripts/road_graph.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("ROAD_GRAPH_ROUTING_TEST: " + message)

func _write_partitions(root_path: String, kind: String, records: Dictionary) -> void:
    var partitions: Dictionary = {}
    for identifier in records.keys():
        var partition := str(identifier).sha1_text().substr(0, 2)
        if not partitions.has(partition):
            partitions[partition] = {}
        partitions[partition][identifier] = records[identifier]
    for partition in partitions.keys():
        var path := "%s/%s_%s.json" % [root_path, kind, partition]
        var file := FileAccess.open(path, FileAccess.WRITE)
        _check(file != null, "Could not write fixture partition " + path)
        if file != null:
            file.store_string(JSON.stringify(partitions[partition]))
            file.close()

func _run() -> void:
    var root_path := "user://road_graph_routing_%d" % Time.get_ticks_usec()
    var absolute := ProjectSettings.globalize_path(root_path)
    _check(DirAccess.make_dir_recursive_absolute(absolute) == OK, "Could not create routing fixture directory")

    var nodes := {
        "n0": {"id": "n0", "position": [0.0, 0.0, 0.0], "edges": ["e_fast", "e_slow_a"]},
        "n1": {"id": "n1", "position": [10.0, 0.0, 0.0], "edges": ["e_slow_a", "e_slow_b"]},
        "n2": {"id": "n2", "position": [20.0, 0.0, 0.0], "edges": ["e_fast", "e_slow_b"]},
    }
    var edges := {
        "e_slow_a": {"id": "e_slow_a", "from": "n0", "to": "n1", "length_m": 10.0, "speed_limit_mps": 5.0, "direction": 1},
        "e_slow_b": {"id": "e_slow_b", "from": "n1", "to": "n2", "length_m": 10.0, "speed_limit_mps": 5.0, "direction": 1},
        "e_fast": {"id": "e_fast", "from": "n0", "to": "n2", "length_m": 30.0, "speed_limit_mps": 30.0, "direction": 1},
    }
    _write_partitions(root_path, "nodes", nodes)
    _write_partitions(root_path, "edges", edges)

    var graph := RoadGraph.new()
    graph.configure(root_path, {"nodes": nodes.size(), "edges": edges.size()})
    _check(graph.route_backend() == "json-fallback", "Source-only graph unexpectedly selected native routing")
    _check(not graph.has_native_routing(), "Source-only graph reported native routing")
    _check(
        graph.route_edge_ids("n0", "n2", false) == PackedStringArray(["e_slow_a", "e_slow_b"]),
        "Distance routing did not choose the shorter two-edge path"
    )
    _check(
        graph.route_edge_ids("n0", "n2", true) == PackedStringArray(["e_fast"]),
        "Travel-time routing did not choose the faster direct edge"
    )
    _check(graph.route_edge_ids("n2", "n0", false).is_empty(), "Forward one-way edges allowed reverse routing")
    _check(graph.route_edge_ids("n0", "n0", false).is_empty(), "Zero-length route should contain no edges")
    _check(graph.route_edge_ids("missing", "n2", false).is_empty(), "Unknown start node did not fail closed")

    graph.clear_cache()
    _check(
        graph.route_edge_ids("n0", "n2", false) == PackedStringArray(["e_slow_a", "e_slow_b"]),
        "Routing changed after JSON partition cache eviction"
    )

    if failures == 0:
        print("YARDMAN_ROAD_GRAPH_ROUTING_TEST PASS backend=json-fallback distance=2 fastest=1 one_way=1 cache_reload=1")
    quit(0 if failures == 0 else 1)
