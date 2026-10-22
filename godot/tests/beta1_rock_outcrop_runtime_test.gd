extends SceneTree

const Rocks = preload("res://scripts/beta1_rock_outcrop_runtime.gd")

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("BETA1_ROCK_OUTCROP_RUNTIME_TEST: " + message)
    quit(1)

func _run() -> void:
    var record := {"a": Vector2(100.0, 100.0), "b": Vector2(300.0, 100.0),
        "width": 6.0, "flags": 0, "seed": 1}
    var slope_sampler := func(point: Vector2) -> float: return 20.0 + point.x * 0.30
    var flat_sampler := func(_point: Vector2) -> float: return 20.0
    var water_clear := func(_point: Vector2) -> float: return 25.0
    var water_near := func(_point: Vector2) -> float: return 5.0

    var plan := Rocks.candidate_plan(record, Vector2i.ZERO, 4096.0, 1.0, slope_sampler, water_clear)
    if plan.is_empty():
        _fail("steep registered terrain candidate was rejected")
        return
    if float(plan.get("grade", 0.0)) < Rocks.MIN_GRADE or float(plan.get("grade", 99.0)) > Rocks.MAX_GRADE:
        _fail("accepted plan escaped grade bounds")
        return
    if float(plan.get("road_clearance_m", 0.0)) < Rocks.MIN_ROAD_CLEARANCE_M + 3.0 \
            or float(plan.get("road_clearance_m", 999.0)) > Rocks.MAX_ROAD_CLEARANCE_M + 3.0:
        _fail("accepted plan escaped pavement clearance envelope")
        return
    if float(plan.get("water_clearance_m", 0.0)) < Rocks.MIN_WATER_CLEARANCE_M:
        _fail("accepted plan violated water clearance")
        return
    if int(plan.get("variant", -1)) < 0 or int(plan.get("variant", 99)) >= Rocks.ROCK_FILES.size():
        _fail("accepted plan selected invalid recovered rock variant")
        return
    if float(plan.get("scale", 0.0)) < 0.55 or float(plan.get("scale", 99.0)) > 0.85:
        _fail("accepted plan escaped bounded presentation scale")
        return
    var basis: Basis = plan.get("basis", Basis())
    if not basis.is_finite():
        _fail("accepted plan produced invalid orientation")
        return

    if not Rocks.candidate_plan(record, Vector2i.ZERO, 4096.0, 1.0, flat_sampler, water_clear).is_empty():
        _fail("flat terrain received recovered boulder")
        return
    if not Rocks.candidate_plan(record, Vector2i.ZERO, 4096.0, 1.0, slope_sampler, water_near).is_empty():
        _fail("known near-water terrain received recovered boulder")
        return
    if not Rocks.candidate_plan(record, Vector2i(2, 2), 4096.0, 1.0, slope_sampler, water_clear).is_empty():
        _fail("candidate escaped source road tile")
        return

    var runtime := Rocks.new()
    var normal := [100.0, 100.0, 300.0, 100.0, 6.0, 2, 0, "road:a", 0, 20.0, 20.0]
    var bridge := normal.duplicate(true)
    bridge[6] = Rocks.BRIDGE_FLAG
    bridge[7] = "road:bridge"
    var tunnel := normal.duplicate(true)
    tunnel[6] = Rocks.TUNNEL_FLAG
    tunnel[7] = "road:tunnel"
    var records := runtime._records([normal, bridge, tunnel])
    runtime.free()
    if records.size() != 1 or int(records[0].get("flags", 99)) != 0:
        _fail("bridge/tunnel segments were not rejected before placement")
        return

    var contract := Rocks.asset_contract()
    var files: Array = contract.get("files", [])
    if files != ["terrain_boulder_01.glb", "terrain_boulder_02.glb"]:
        _fail("recovered boulder filenames drifted")
        return
    if not bool(contract.get("presentation_inference", false)) or bool(contract.get("geology_truth", true)):
        _fail("boulders gained unsupported geology authority")
        return
    if bool(contract.get("terrain_mutation", true)) or bool(contract.get("collision", true)):
        _fail("boulders gained terrain/collision authority")
        return
    if int(contract.get("max_per_tile", 99)) > 8 or int(contract.get("max_per_cell", 99)) > 2:
        _fail("boulder density budget expanded")
        return
    if not bool(contract.get("asset_absent_fallback", false)):
        _fail("asset-absent fallback is not explicit")
        return

    print("YARDMAN_BETA1_ROCK_OUTCROP_RUNTIME_TEST PASS steep=1 flat_rejected=1 water_rejected=1 bridge_rejected=1 tunnel_rejected=1 tile_bound=1 max_tile=8 max_cell=2 geology=0 collision=0")
    quit(0)
