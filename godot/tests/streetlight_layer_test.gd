extends SceneTree

const StreetLightLayer = preload("res://scripts/streetlight_layer.gd")

func _initialize() -> void:
    var layer := StreetLightLayer.new()
    var tile := Vector2i(-1, -1)
    var records := [
        {"source_node": "n1", "position": [-1320.18, -3025.769], "highway": "street_lamp", "lamp_mount": "unspecified", "support": "unspecified"},
        {"source_node": "n2", "position": [-1489.998, -3106.024], "highway": "street_lamp"},
        {"source_node": "n2", "position": [-1490.0, -3106.0], "highway": "street_lamp"},
        {"source_node": "bad-kind", "position": [-1400.0, -3000.0], "highway": "traffic_signals"},
        {"source_node": "wrong-tile", "position": [5000.0, 5000.0], "highway": "street_lamp"},
    ]
    var plan: Array[Dictionary] = layer.placement_plan(records, tile, 4096.0)
    _require(plan.size() == 2, "expected two unique explicit street lamps")
    _require(str(plan[0].source_node) == "n1" and str(plan[1].source_node) == "n2", "source identity changed")
    _require(is_equal_approx(float(plan[0].local_x), -1320.18 + 4096.0), "local X is not tile-relative")
    _require(is_equal_approx(float(plan[0].local_z), -3025.769 + 4096.0), "local Z is not tile-relative")
    _require(str(plan[0].lamp_mount) == "unspecified" and str(plan[0].support) == "unspecified", "unspecified metadata was invented")

    _require(layer.placement_plan(records, tile, 0.0).is_empty(), "invalid tile size must fail closed")
    var mesh: ArrayMesh = layer._get_fallback_mesh()
    _require(mesh != null and mesh.get_surface_count() == 1, "fallback mesh missing")
    var bounds := mesh.get_aabb()
    _require(bounds.size.y > 8.2 and bounds.size.y < 9.0, "fallback height escaped audited range")
    _require(bounds.size.x < 1.0 and bounds.size.z < 1.0, "fallback must remain orientation-neutral")
    layer.free()
    print("YARDMAN_STREETLIGHT_LAYER_TEST PASS placements=%d height=%.3f width=%.3f" % [plan.size(), bounds.size.y, bounds.size.x])
    quit(0)

func _require(condition: bool, message: String) -> void:
    if condition:
        return
    push_error("YARDMAN_STREETLIGHT_LAYER_TEST FAIL: " + message)
    quit(2)
