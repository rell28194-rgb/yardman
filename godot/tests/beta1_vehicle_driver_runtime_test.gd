extends SceneTree

const DriverRuntime = preload("res://scripts/beta1_vehicle_driver_runtime.gd")

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("BETA1_VEHICLE_DRIVER_RUNTIME_TEST: " + message)
    quit(1)

func _run() -> void:
    var contract := DriverRuntime.driver_contract()
    if str(contract.get("file", "")) != "road_driver_seated.glb":
        _fail("recovered driver filename drifted")
        return
    if contract.get("position_m", Vector3.INF) != Vector3(0.91, 0.21, -0.187):
        _fail("validated RHD sedan fit position drifted")
        return
    if contract.get("rotation_rad", Vector3.INF) != Vector3.ZERO or contract.get("scale", Vector3.ZERO) != Vector3.ONE:
        _fail("validated source rotation/scale changed")
        return
    if int(contract.get("source_vertices", 0)) != 3986 or int(contract.get("source_triangles", 0)) != 6066 or int(contract.get("source_bones", 0)) != 60:
        _fail("recovered source identity/provenance counts drifted")
        return
    if not bool(contract.get("static_seated_pose", false)) or not bool(contract.get("combined_sedan_driver_render", false)):
        _fail("validated static seated source/render contract missing")
        return
    if not bool(contract.get("visibility_follows_occupancy", false)):
        _fail("driver no longer follows vehicle occupancy")
        return
    if bool(contract.get("collision", true)) or bool(contract.get("on_foot_replacement", true)):
        _fail("driver gained collision or on-foot character authority")
        return
    if not bool(contract.get("asset_absent_fallback", false)):
        _fail("source-only fallback is not explicit")
        return

    # Public/source-only CI intentionally lacks the private GLB. The runtime
    # must remain safe before RoadQA exists and while private media is absent.
    var host := Node3D.new()
    root.add_child(host)
    var runtime := DriverRuntime.new()
    host.add_child(runtime)
    runtime._try_attach()
    if runtime._attached:
        _fail("driver attached without a validated reference vehicle")
        return
    host.queue_free()
    await process_frame

    print("YARDMAN_BETA1_VEHICLE_DRIVER_RUNTIME_TEST PASS fit=1 rhd=1 occupancy=1 collision=0 onfoot=0 fallback=1")
    quit(0)
