extends SceneTree

const References = preload("res://scripts/reference_assets.gd")
const RemoteFleetRuntime = preload("res://scripts/remote_fleet_runtime.gd")

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("OWNER_WIFI_FLEET_BASE: " + message)
    quit(1)

func _run() -> void:
    if RemoteFleetRuntime.PACK_BYTES != 159594070:
        _fail("unexpected remote pack byte contract")
        return
    if RemoteFleetRuntime.CHUNK_BYTES != 4 * 1024 * 1024:
        _fail("unexpected resumable chunk contract")
        return
    if str(RemoteFleetRuntime.PACK_SHA256) != "6b1130bcd9a6ab554c3134710b348050d1a03e40c6c3f16136fefbeda5c5e75b":
        _fail("unexpected remote pack digest contract")
        return
    if not References.exact_asset_exists("toyota_crown_2013.glb"):
        _fail("accepted Crown cache/source missing")
        return
    var crown := References.scene("toyota_crown_2013.glb")
    if not crown is PackedScene:
        _fail("accepted Crown scene failed to load")
        return

    var err := change_scene_to_file("res://main.tscn")
    if err != OK:
        _fail("main scene failed to load: %s" % err)
        return
    for _i in range(30):
        await process_frame

    var remote := root.get_node_or_null("RemoteFleet")
    if remote == null:
        _fail("RemoteFleet autoload missing")
        return
    if str(remote.call("get_state")) not in ["idle", "installed"]:
        _fail("unexpected downloader state=%s" % str(remote.call("get_state")))
        return

    var garage := root.get_node_or_null("VehicleGarage")
    if garage == null:
        _fail("VehicleGarage autoload missing")
        return
    for _i in range(20):
        await process_frame
    var ids: Array = garage.get("_vehicle_ids")
    if not ids.has("toyota_crown"):
        _fail("accepted Crown missing from lightweight garage")
        return
    if ids.size() != 1:
        _fail("lightweight APK unexpectedly embeds %d vehicles; expected Crown only" % ids.size())
        return
    var button = garage.get("_button")
    var download_button = garage.get("_download_button")
    if button == null or not str(button.text).begins_with("GARAGE"):
        _fail("GARAGE control missing")
        return
    if download_button == null or "DOWNLOAD" not in str(download_button.text):
        _fail("post-install vehicle download control missing")
        return
    if str(garage.get("_current_id")) != "toyota_crown":
        _fail("default vehicle is not accepted Crown")
        return

    var bridge := root.get_node_or_null("SystemMenuBridge")
    if bridge == null:
        _fail("consolidated system menu bridge missing")
        return

    print("YARDMAN_OWNER_WIFI_FLEET_BASE_PASS base=toyota_crown embedded=1 remote_pack_bytes=%d resumable=4194304 garage=download-ready hud=consolidated" % RemoteFleetRuntime.PACK_BYTES)
    quit(0)
