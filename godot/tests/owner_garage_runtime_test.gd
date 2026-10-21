extends SceneTree

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("OWNER_GARAGE_RUNTIME: " + message)
    quit(1)

func _run() -> void:
    var err := change_scene_to_file("res://main.tscn")
    if err != OK:
        _fail("main scene failed to load: %s" % err)
        return
    for _i in range(20):
        await process_frame
    var garage := root.get_node_or_null("VehicleGarage")
    if garage == null:
        _fail("VehicleGarage autoload missing")
        return
    for _i in range(20):
        await process_frame
    var ids: Array = garage.get("_vehicle_ids")
    if ids.size() != 64:
        _fail("garage selector count=%d expected=64" % ids.size())
        return
    var button = garage.get("_button")
    if button == null or not str(button.text).begins_with("GARAGE"):
        _fail("GARAGE control missing")
        return
    var current := str(garage.get("_current_id"))
    if current != "toyota_crown":
        _fail("default vehicle=%s expected toyota_crown" % current)
        return
    if not bool(garage.call("_apply_vehicle", "audi_r8", false)):
        _fail("Crown -> Audi R8 runtime switch failed")
        return
    if str(garage.get("_current_id")) != "audi_r8":
        _fail("Audi R8 not active after switch")
        return
    if not bool(garage.call("_apply_vehicle", "toyota_crown", false)):
        _fail("Audi R8 -> Crown runtime switch failed")
        return
    if str(garage.get("_current_id")) != "toyota_crown":
        _fail("Crown not restored after switch")
        return
    print("YARDMAN_OWNER_GARAGE_RUNTIME_PASS selector=64 default=toyota_crown switch=toyota_crown>audi_r8>toyota_crown")
    quit(0)
