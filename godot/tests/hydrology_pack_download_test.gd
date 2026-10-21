extends SceneTree

const HYDROLOGY_BYTES := 844549
const EXPECTED_TILES := 421
const TIMEOUT_SECONDS := 90.0

var _done := false
var _failed := ""

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    _failed = message
    _done = true

func _run() -> void:
    var manager := root.get_node_or_null("ContentPacks")
    if manager == null:
        _fail("ContentPacks autoload missing")
        _finish()
        return

    var status: Dictionary = manager.call("pack_status", "hydrology")
    if not bool(status.get("available", false)):
        _fail("hydrology pack is not marked downloadable")
        _finish()
        return
    if int(status.get("bytes", 0)) != HYDROLOGY_BYTES:
        _fail("hydrology byte contract drifted")
        _finish()
        return

    manager.pack_installed.connect(func(pack_id: String, version: int) -> void:
        if pack_id == "hydrology" and version == 1:
            _done = true)
    manager.pack_state_changed.connect(func(pack_id: String, state: String, message: String) -> void:
        if pack_id == "hydrology" and state == "error":
            _fail(message))

    if not bool(manager.call("start_pack", "hydrology")):
        _fail("ContentPacks refused to start hydrology download")
        _finish()
        return

    var start_msec := Time.get_ticks_msec()
    while not _done and float(Time.get_ticks_msec() - start_msec) / 1000.0 < TIMEOUT_SECONDS:
        await process_frame

    if not _done:
        _fail("hydrology download/install timed out")

    if not _failed.is_empty():
        _finish()
        return

    var manifest_path := "user://yardman/packs/hydrology/manifest.json"
    if not FileAccess.file_exists(manifest_path):
        _fail("installed hydrology manifest missing")
        _finish()
        return
    var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
    if not raw is Dictionary:
        _fail("installed hydrology manifest invalid")
        _finish()
        return
    var manifest: Dictionary = raw as Dictionary
    if int(manifest.get("format_version", 0)) != 1:
        _fail("installed hydrology format version invalid")
        _finish()
        return
    if int((manifest.get("stats", {}) as Dictionary).get("tiles", 0)) != EXPECTED_TILES:
        _fail("installed hydrology tile count drifted")
        _finish()
        return
    if (manifest.get("tiles", []) as Array).size() != EXPECTED_TILES:
        _fail("installed hydrology tile index incomplete")
        _finish()
        return

    var water := root.get_node_or_null("RunningWater")
    if water == null:
        _fail("RunningWater autoload missing")
        _finish()
        return
    water.set("_manifest", {})
    water.set("_tile_files", {})
    water.set("_root", "")
    if not bool(water.call("_load_manifest")):
        _fail("RunningWater did not accept installed hydrology manifest")
        _finish()
        return
    if str(water.get("_root")) != "user://yardman/packs/hydrology/":
        _fail("RunningWater resolved wrong hydrology root")
        _finish()
        return
    var files: Dictionary = water.get("_tile_files") as Dictionary
    if files.size() != EXPECTED_TILES:
        _fail("RunningWater indexed incomplete hydrology tiles")
        _finish()
        return

    print("YARDMAN_HYDROLOGY_RUNTIME_DOWNLOAD_PASS bytes=%d tiles=%d install=user://yardman/packs/hydrology" % [HYDROLOGY_BYTES, EXPECTED_TILES])
    quit(0)

func _finish() -> void:
    if _failed.is_empty():
        quit(0)
        return
    push_error("HYDROLOGY_PACK_DOWNLOAD: " + _failed)
    quit(1)
