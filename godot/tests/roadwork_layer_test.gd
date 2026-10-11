extends SceneTree

const RoadworkScript = preload("res://scripts/roadwork_layer.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("ROADWORK_LAYER_TEST: " + message)

func _record(source: String, start: Array, finish: Array, width: float = 6.0) -> Dictionary:
    return {
        "source_way": source,
        "start": start,
        "end": finish,
        "width_m": width,
        "class": "primary",
        "construction": "resurfacing",
    }

func _run() -> void:
    var layer = RoadworkScript.new()
    root.add_child(layer)

    _check(layer.placement_plan([], Vector2i.ZERO, 4096.0).is_empty(), "empty records produced cones")
    _check(layer.placement_plan([_record("bad-size", [0.0, 0.0], [20.0, 0.0])], Vector2i.ZERO, 0.0).is_empty(), "invalid tile size produced cones")

    # A malformed record must not suppress later valid roadwork records.
    var mixed: Array = ["bad-record", _record("w101", [4100.0, 20.0], [4200.0, 20.0])]
    var plan: Array = layer.placement_plan(mixed, Vector2i(1, 0), 4096.0)
    _check(plan.size() == 3, "100 m valid record after malformed input should create three bounded samples")
    for item in plan:
        _check(item is Dictionary, "placement item is not a dictionary")
        if not item is Dictionary:
            continue
        var world_x := float(item.get("world_x", NAN))
        var world_z := float(item.get("world_z", NAN))
        var local_x := float(item.get("local_x", NAN))
        var local_z := float(item.get("local_z", NAN))
        _check(is_finite(world_x) and is_finite(world_z), "placement contains non-finite world coordinates")
        _check(absf(local_x - (world_x - 4096.0)) < 0.0001, "X tile-local coordinate is not registered to the 4096 m tile origin")
        _check(absf(local_z - world_z) < 0.0001, "Z tile-local coordinate changed in zero-Z tile")
        _check(absf(absf(world_z - 20.0) - 3.55) < 0.0001, "cone is not outside the 6 m carriageway by the bounded 0.55 m offset")
        _check(str(item.get("source_way", "")) == "w101", "source-way identity was lost")

    # Many tagged fragments can never exceed the per-streamed-tile budget.
    var crowded: Array = []
    for index in range(40):
        crowded.append(_record("crowd-%d" % index, [0.0, float(index) * 8.0], [100.0, float(index) * 8.0]))
    var capped: Array = layer.placement_plan(crowded, Vector2i.ZERO, 4096.0)
    _check(capped.size() == 32, "roadwork placement exceeded or failed to fill the 32-cone tile budget")

    # Degenerate and non-finite fragments are ignored rather than becoming world geometry.
    var invalid: Array = [
        _record("tiny", [0.0, 0.0], [0.1, 0.1]),
        _record("nan", [NAN, 0.0], [10.0, 0.0]),
        {"source_way": "short", "start": [1.0], "end": [2.0]},
    ]
    _check(layer.placement_plan(invalid, Vector2i.ZERO, 4096.0).is_empty(), "invalid fragments produced roadwork geometry")

    layer.queue_free()
    await process_frame
    print("YARDMAN_ROADWORK_LAYER_TEST %s malformed_skip=1 metre_registration=1 lateral_bound=1 cap=32 invalid_reject=1" % ("PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)
