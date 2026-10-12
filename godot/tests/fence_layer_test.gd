extends SceneTree

const FenceLayerScript = preload("res://scripts/fence_layer.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("FENCE_LAYER_TEST: " + message)

func _run() -> void:
    var layer = FenceLayerScript.new()
    var lengths: Array[float] = [64.6862640380859, 52.0559234619141, 21.6249980926514]
    var records := [
        {"source_way": "wire-long", "wire_compatible": true, "start": [100.0, 200.0], "end": [230.0, 200.0]},
        {"source_way": "generic", "wire_compatible": false, "start": [0.0, 10.0], "end": [130.0, 10.0]},
        {"source_way": "bad", "wire_compatible": true, "start": [NAN, 0.0], "end": [80.0, 0.0]},
    ]
    var plan := layer.placement_plan(records, Vector2i.ZERO, 4096.0, lengths)
    _check(plan.size() == 2, "130m explicit wire fence should use two 64.686m source runs and ignore generic/bad records")
    for item: Dictionary in plan:
        _check(is_equal_approx(float(item.length), lengths[0]), "Planner stretched or substituted the audited source run")
        _check(not item.has("scale"), "Planner introduced a source-length scale factor")
        _check(is_finite(float(item.world_x)) and is_finite(float(item.world_z)), "Planner emitted non-finite placement")

    var medium := layer.placement_plan([{"wire_compatible": true, "start": [0.0, 0.0], "end": [60.0, 0.0]}], Vector2i.ZERO, 4096.0, lengths)
    _check(medium.size() == 1 and is_equal_approx(float(medium[0].length), lengths[1]), "60m run should select the 52.056m source mesh without scaling")
    var short := layer.placement_plan([{"wire_compatible": true, "start": [0.0, 0.0], "end": [15.0, 0.0]}], Vector2i.ZERO, 4096.0, lengths)
    _check(short.is_empty(), "Sub-source-length fence should be skipped rather than compressed")

    var many: Array = []
    for index in range(80):
        many.append({"wire_compatible": true, "start": [0.0, float(index) * 4.0], "end": [80.0, float(index) * 4.0]})
    var capped := layer.placement_plan(many, Vector2i.ZERO, 4096.0, lengths)
    _check(capped.size() == FenceLayerScript.MAX_INSTANCES_PER_TILE, "Per-tile private fence budget was not enforced")
    layer.free()
    print("YARDMAN_FENCE_LAYER_TEST %s source_scale=1 strict_style=1 cap=%d" % [("PASS" if failures == 0 else "FAIL"), FenceLayerScript.MAX_INSTANCES_PER_TILE])
    quit(0 if failures == 0 else 1)
