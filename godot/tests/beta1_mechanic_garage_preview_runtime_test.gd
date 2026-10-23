extends SceneTree

const Preview = preload("res://scripts/beta1_mechanic_garage_preview_runtime.gd")

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("BETA1_MECHANIC_GARAGE_PREVIEW_TEST: " + message)
    quit(1)

func _run() -> void:
    var contract := Preview.preview_contract()
    var files: Array = contract.get("files", [])
    if files != [
        "garage_tire_changer.glb",
        "garage_tire_balancer.glb",
        "garage_grinder.glb",
        "garage_polisher.glb",
        "garage_screw_extractor.glb",
    ]:
        _fail("default recovered Mechanic family drifted")
        return
    var viewport: Vector2i = contract.get("viewport", Vector2i.ZERO)
    if viewport.x <= 0 or viewport.y <= 0 or viewport.x > 384 or viewport.y > 216:
        _fail("preview viewport exceeded bounded Android budget")
        return
    if int(contract.get("max_recovered_props", 99)) != 5:
        _fail("preview prop budget drifted")
        return
    if str(contract.get("render_mode", "")) != "one-shot-on-garage-open" \
            or str(contract.get("garage_surface", "")) != "/root/VehicleGarage":
        _fail("preview is no longer tied to the existing garage UI")
        return
    if not bool(contract.get("lazy_build", false)) or bool(contract.get("continuous_rendering", true)):
        _fail("preview lost lazy/one-shot rendering contract")
        return
    for forbidden in ["jamaica_world_placement", "physics", "collision", "navigation"]:
        if bool(contract.get(forbidden, true)):
            _fail("preview gained forbidden world authority: " + forbidden)
            return
    if not bool(contract.get("source_scale_preserved", false)) or not bool(contract.get("asset_absent_fallback", false)):
        _fail("source-scale or asset-absent fallback contract missing")
        return

    # The public repository intentionally omits private Mechanic media. Exact
    # optional lookups must remain safe and must not create any preview nodes.
    var runtime := Preview.new()
    root.add_child(runtime)
    await process_frame
    if runtime.get_child_count() != 0:
        _fail("preview allocated a 3D renderer without an open garage/private media")
        return
    runtime.queue_free()
    await process_frame

    print("YARDMAN_BETA1_MECHANIC_GARAGE_PREVIEW_TEST PASS assets=5 lazy=1 one_shot=1 viewport=384x216 world_placement=0 continuous=0 physics=0 collision=0 navigation=0 fallback=1")
    quit(0)
