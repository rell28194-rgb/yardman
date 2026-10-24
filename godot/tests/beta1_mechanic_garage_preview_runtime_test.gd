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
    if not bool(contract.get("vehicle_preview", false)) \
            or str(contract.get("vehicle_selection_mode", "")) != "highlight-before-use" \
            or str(contract.get("vehicle_render_trigger", "")) != "selection-change" \
            or int(contract.get("max_vehicle_models", 99)) != 1 \
            or str(contract.get("fleet_source", "")) != "/root/VehicleGarage":
        _fail("garage browse vehicle-preview contract drifted")
        return
    if str(contract.get("layout_mode", "")) != "responsive-side-by-side" \
            or bool(contract.get("overlap_controls", true)) \
            or str(contract.get("narrow_screen_fallback", "")) != "hide-preview-keep-garage" \
            or not is_equal_approx(float(contract.get("layout_gap_px", 0.0)), 14.0) \
            or not is_equal_approx(float(contract.get("min_screen_margin_px", 0.0)), 12.0):
        _fail("responsive garage layout contract drifted")
        return
    for forbidden in ["jamaica_world_placement", "physics", "collision", "navigation"]:
        if bool(contract.get(forbidden, true)):
            _fail("preview gained forbidden world authority: " + forbidden)
            return
    if not bool(contract.get("source_scale_preserved", false)) or not bool(contract.get("asset_absent_fallback", false)):
        _fail("source-scale or asset-absent fallback contract missing")
        return

    var ids: Array = ["toyota_crown", "mazda_rx7", "nissan_skyline_r34"]
    if Preview.preview_vehicle_id(ids, 1, "toyota_crown") != "mazda_rx7":
        _fail("highlighted option does not drive preview identity")
        return
    if Preview.preview_vehicle_id(ids, -1, "toyota_crown") != "toyota_crown" \
            or Preview.preview_vehicle_id(ids, 99, "toyota_crown") != "toyota_crown":
        _fail("invalid option index does not fall back to active vehicle")
        return

    var normal_scale := Preview.preview_scale_for(AABB(Vector3(-0.95, 0.0, -2.25), Vector3(1.9, 1.4, 4.5)))
    var long_scale := Preview.preview_scale_for(AABB(Vector3(-1.35, 0.0, -5.0), Vector3(2.7, 3.4, 10.0)))
    var invalid_scale := Preview.preview_scale_for(AABB(Vector3.ZERO, Vector3.ZERO))
    if normal_scale <= 0.38 or normal_scale > 1.0:
        _fail("normal vehicle preview scale escaped bounds")
        return
    if long_scale < 0.38 or long_scale >= normal_scale:
        _fail("large vehicle was not reduced more than normal vehicle")
        return
    if not is_equal_approx(invalid_scale, 1.0):
        _fail("invalid preview bounds did not use safe unit scale")
        return

    var garage_size := Vector2(410.0, 320.0)
    var preview_size := Vector2(404.0, 256.0)
    var wide := Preview.paired_layout(Vector2(1280.0, 720.0), garage_size, preview_size)
    if not bool(wide.get("paired", false)):
        _fail("1280-wide screen did not pair garage and preview")
        return
    var wide_preview_pos: Vector2 = wide.get("preview_position", Vector2.ZERO)
    var wide_garage_pos: Vector2 = wide.get("garage_position", Vector2.ZERO)
    if not wide_preview_pos.is_equal_approx(Vector2(-414.0, -128.0)) \
            or not wide_garage_pos.is_equal_approx(Vector2(4.0, -160.0)):
        _fail("wide paired layout is not centered with the required gap")
        return
    if Rect2(wide_preview_pos, preview_size).intersects(Rect2(wide_garage_pos, garage_size)):
        _fail("wide preview overlaps garage controls")
        return

    var medium := Preview.paired_layout(Vector2(960.0, 540.0), garage_size, preview_size)
    if not bool(medium.get("paired", false)):
        _fail("960-wide screen unnecessarily hid the preview")
        return
    var medium_preview: Rect2 = Rect2(medium.get("preview_position", Vector2.ZERO), preview_size)
    var medium_garage: Rect2 = Rect2(medium.get("garage_position", Vector2.ZERO), garage_size)
    if medium_preview.intersects(medium_garage):
        _fail("medium preview overlaps garage controls")
        return

    var narrow := Preview.paired_layout(Vector2(800.0, 480.0), garage_size, preview_size)
    if bool(narrow.get("paired", true)):
        _fail("narrow screen did not fall back to garage-only layout")
        return
    var narrow_garage: Vector2 = narrow.get("garage_position", Vector2.ZERO)
    if not narrow_garage.is_equal_approx(Vector2(-205.0, -160.0)):
        _fail("narrow fallback did not keep garage centered")
        return

    # Public/source-only builds intentionally omit private vehicle/Mechanic media.
    # Without an open garage this runtime must still allocate no second renderer.
    var runtime := Preview.new()
    root.add_child(runtime)
    await process_frame
    if runtime.get_child_count() != 0:
        _fail("preview allocated a 3D renderer without an open garage/private media")
        return
    runtime.queue_free()
    await process_frame

    print("YARDMAN_BETA1_MECHANIC_GARAGE_PREVIEW_TEST PASS assets=5 lazy=1 one_shot=1 viewport=384x216 world_placement=0 continuous=0 physics=0 collision=0 navigation=0 fallback=1 vehicle_preview=1 browse_before_use=1 max_vehicle=1 selection_render=1 responsive_layout=1 no_overlap=1 narrow_fallback=1")
    quit(0)
