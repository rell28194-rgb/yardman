extends SceneTree

const BusStopLayer = preload("res://scripts/bus_stop_layer.gd")

func _initialize() -> void:
    var layer := BusStopLayer.new()
    var records := [
        {"source_node": "n1", "position": [-1320.18, -3025.769], "kind": "highway=bus_stop", "shelter": "yes", "bench": "unspecified"},
        {"source_node": "n2", "position": [-1489.998, -3106.024], "kind": "public_transport=platform+bus", "shelter": "unspecified", "bench": "yes"},
        {"source_node": "n2", "position": [-1490.0, -3106.0], "kind": "highway=bus_stop"},
        {"source_node": "bad-kind", "position": [-1400.0, -3000.0], "kind": "amenity=shelter"},
        {"source_node": "wrong-tile", "position": [5000.0, 5000.0], "kind": "highway=bus_stop"},
    ]
    var plan: Array[Dictionary] = layer.placement_plan(records, Vector2i(-1, -1), 4096.0)
    _require(plan.size() == 2, "expected two unique explicit bus stops")
    _require(str(plan[0].source_node) == "n1" and str(plan[1].source_node) == "n2", "source identity changed")
    _require(bool(plan[0].shelter_explicit), "source shelter=yes was lost")
    _require(not bool(plan[0].bench_explicit), "unspecified bench was invented")
    _require(bool(plan[1].bench_explicit), "source bench=yes was lost")
    _require(not bool(plan[1].shelter_explicit), "unspecified shelter was invented")
    _require(layer.placement_plan(records, Vector2i(-1, -1), 0.0).is_empty(), "invalid tile size must fail closed")

    var marker: ArrayMesh = layer._get_marker_mesh()
    _require(marker != null and marker.get_surface_count() == 1, "neutral stop marker mesh missing")
    var marker_bounds := marker.get_aabb()
    _require(marker_bounds.size.y > 2.7 and marker_bounds.size.y < 3.2, "marker height escaped audited range")
    _require(marker_bounds.size.x < 0.6 and marker_bounds.size.z < 0.6, "marker must remain orientation-neutral")

    var shelter: ArrayMesh = layer._get_shelter_mesh()
    _require(shelter != null and shelter.get_surface_count() == 1, "explicit shelter mesh missing")
    var shelter_bounds := shelter.get_aabb()
    _require(shelter_bounds.size.y > 2.2 and shelter_bounds.size.y < 2.6, "shelter height escaped compact stop range")
    _require(shelter_bounds.size.x > 1.4 and shelter_bounds.size.x < 1.8, "shelter canopy width invalid")
    _require(absf(shelter_bounds.size.x - shelter_bounds.size.z) < 0.02, "shelter gained an invented road-facing orientation")

    var bench: ArrayMesh = layer._get_bench_mesh()
    _require(bench != null and bench.get_surface_count() == 1, "explicit bench mesh missing")
    var bench_bounds := bench.get_aabb()
    _require(bench_bounds.size.y > 0.45 and bench_bounds.size.y < 0.60, "bench height invalid")
    _require(bench_bounds.size.x > 1.0 and bench_bounds.size.x < 1.25, "bench footprint invalid")
    _require(absf(bench_bounds.size.x - bench_bounds.size.z) < 0.02, "bench gained an invented road-facing orientation")

    layer.free()
    print("YARDMAN_BUS_STOP_LAYER_TEST PASS placements=%d marker_h=%.3f shelter_h=%.3f bench_h=%.3f" % [plan.size(), marker_bounds.size.y, shelter_bounds.size.y, bench_bounds.size.y])
    quit(0)

func _require(condition: bool, message: String) -> void:
    if condition:
        return
    push_error("YARDMAN_BUS_STOP_LAYER_TEST FAIL: " + message)
    quit(2)
