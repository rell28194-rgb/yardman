extends Node
class_name YardmanHydrologyContentRuntime

signal state_changed(state: String, message: String)
signal progress_changed(downloaded_bytes: int, total_bytes: int)
signal installed

const Renderer = preload("res://scripts/hydrology_renderer.gd")
const PACK_ID := "jamaica_hydrology_osm_v1"
const RELEASE_ROOT := "https://github.com/rell28194-rgb/yardman/releases/download/yardman-hydrology-v1"
const PACK_URL := RELEASE_ROOT + "/Yardman-Jamaica-Hydrology-v1.zip"
const PACK_SHA256 := "6855fcda76dc85a746eb179f966ed889a6715c2f53d776563f5344ebccce1811"
const PACK_BYTES := 662099
const MANIFEST_SHA256 := "10987e554748bb16680be0f971bf836a5d8057a9c2cd338cb6930987977e0ccb"
const ROOT := "user://yardman/content/jamaica_hydrology_osm_v1/"
const ARCHIVE_PATH := "user://yardman/jamaica-hydrology-v1.zip.part"
const MANIFEST_PATH := ROOT + "manifest.json"
const MARKER_PATH := ROOT + "installed.json"
const UPDATE_INTERVAL := 0.45

var _http: HTTPRequest
var _state := "idle"
var _message := "Jamaica running water is optional."
var _last_progress_emit_msec := 0
var _update_accumulator := 0.0
var _renderer: YardmanHydrologyRenderer
var _bound_game: Node

var _layer: CanvasLayer
var _button: Button
var _panel: PanelContainer
var _status: Label
var _progress: ProgressBar
var _download_button: Button

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://yardman"))
    _http = HTTPRequest.new()
    _http.use_threads = true
    _http.accept_gzip = false
    _http.body_size_limit = -1
    _http.download_chunk_size = 262144
    _http.max_redirects = 8
    _http.timeout = 0.0
    _http.request_completed.connect(_on_request_completed)
    add_child(_http)
    _build_ui()
    set_process(true)
    if is_installed():
        _set_state("installed", "Jamaica rivers and streams installed · streamed running water active.")
    else:
        _set_state("idle", "Jamaica rivers + streams available · Wi-Fi recommended · 0.7 MB.")

func _process(delta: float) -> void:
    if _state == "downloading" and _http != null:
        var now := Time.get_ticks_msec()
        if now - _last_progress_emit_msec >= 150:
            _last_progress_emit_msec = now
            _emit_progress(maxi(int(_http.get_downloaded_bytes()), 0))
    if _state != "installed":
        return
    _update_accumulator += delta
    if _update_accumulator < UPDATE_INTERVAL:
        return
    _update_accumulator = 0.0
    _update_renderer()

func _build_ui() -> void:
    _layer = CanvasLayer.new()
    _layer.layer = 43
    add_child(_layer)

    _button = Button.new()
    _button.text = "RIVERS"
    _button.position = Vector2(190, 18)
    _button.size = Vector2(164, 46)
    _button.focus_mode = Control.FOCUS_NONE
    _button.pressed.connect(func() -> void: _panel.visible = not _panel.visible)
    _layer.add_child(_button)

    _panel = PanelContainer.new()
    _panel.position = Vector2(190, 72)
    _panel.size = Vector2(430, 250)
    _panel.visible = false
    _layer.add_child(_panel)

    var column := VBoxContainer.new()
    column.add_theme_constant_override("separation", 8)
    _panel.add_child(column)

    var title := Label.new()
    title.text = "JAMAICA RUNNING WATER"
    title.add_theme_font_size_override("font_size", 19)
    column.add_child(title)

    var detail := Label.new()
    detail.text = "Real OSM river / stream / canal geometry · terrain-draped · 3×3 streamed tiles"
    detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    column.add_child(detail)

    _status = Label.new()
    _status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    column.add_child(_status)

    _progress = ProgressBar.new()
    _progress.min_value = 0.0
    _progress.max_value = 100.0
    _progress.value = 0.0
    _progress.show_percentage = true
    column.add_child(_progress)

    var actions := HBoxContainer.new()
    actions.add_theme_constant_override("separation", 8)
    column.add_child(actions)

    _download_button = Button.new()
    _download_button.text = "DOWNLOAD RUNNING WATER"
    _download_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _download_button.focus_mode = Control.FOCUS_NONE
    _download_button.pressed.connect(start_download)
    actions.add_child(_download_button)

    var close := Button.new()
    close.text = "CLOSE"
    close.focus_mode = Control.FOCUS_NONE
    close.pressed.connect(func() -> void: _panel.visible = false)
    actions.add_child(close)

    var attribution := Label.new()
    attribution.text = "Data: © OpenStreetMap contributors · ODbL"
    attribution.add_theme_font_size_override("font_size", 12)
    column.add_child(attribution)

func get_state() -> String:
    return _state

func get_message() -> String:
    return _message

func is_installed() -> bool:
    if not FileAccess.file_exists(MARKER_PATH) or not FileAccess.file_exists(MANIFEST_PATH):
        return false
    var marker = JSON.parse_string(FileAccess.get_file_as_string(MARKER_PATH))
    if not marker is Dictionary:
        return false
    return str(marker.get("pack_id", "")) == PACK_ID \
        and str(marker.get("pack_sha256", "")).to_lower() == PACK_SHA256 \
        and str(marker.get("manifest_sha256", "")).to_lower() == MANIFEST_SHA256

func start_download() -> void:
    if is_installed():
        _set_state("installed", "Jamaica rivers and streams already installed.")
        installed.emit()
        return
    if _state in ["downloading", "verifying", "installing"]:
        return
    if FileAccess.file_exists(ARCHIVE_PATH):
        DirAccess.remove_absolute(ProjectSettings.globalize_path(ARCHIVE_PATH))
    _http.download_file = ARCHIVE_PATH
    _set_state("downloading", "Downloading Jamaica running-water data…")
    _emit_progress(0)
    var err := _http.request(PACK_URL)
    if err != OK:
        _set_state("error", "Could not start hydrology download (%s)." % error_string(err))

func cancel_download() -> void:
    if _state == "downloading" and _http != null:
        _http.cancel_request()
        _set_state("idle", "Hydrology download paused. Tap download to restart.")

func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
    if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
        _set_state("error", "Hydrology download failed. Tap download to retry.")
        return
    var handle := FileAccess.open(ARCHIVE_PATH, FileAccess.READ)
    var size: int = int(handle.get_length()) if handle != null else -1
    if size != PACK_BYTES:
        _set_state("error", "Hydrology download is incomplete (%d / %d bytes). Tap download to retry." % [maxi(size, 0), PACK_BYTES])
        return
    _set_state("verifying", "Verifying Jamaica hydrology pack…")
    if FileAccess.get_sha256(ARCHIVE_PATH).to_lower() != PACK_SHA256:
        DirAccess.remove_absolute(ProjectSettings.globalize_path(ARCHIVE_PATH))
        _set_state("error", "Hydrology verification failed. Bad data was discarded.")
        return
    _set_state("installing", "Installing streamed river tiles…")
    if not _extract_archive() or not _verify_extracted():
        _set_state("error", "Hydrology pack could not be installed safely.")
        return
    var marker := FileAccess.open(MARKER_PATH, FileAccess.WRITE)
    if marker == null:
        _set_state("error", "Could not save hydrology installation state.")
        return
    marker.store_string(JSON.stringify({
        "pack_id": PACK_ID,
        "pack_sha256": PACK_SHA256,
        "manifest_sha256": MANIFEST_SHA256,
        "pack_bytes": PACK_BYTES,
        "installed_at_unix": int(Time.get_unix_time_from_system())
    }))
    marker.close()
    DirAccess.remove_absolute(ProjectSettings.globalize_path(ARCHIVE_PATH))
    _set_state("installed", "Jamaica rivers and streams installed · streamed running water active.")
    _emit_progress(PACK_BYTES)
    installed.emit()

func _extract_archive() -> bool:
    var reader := ZIPReader.new()
    if reader.open(ARCHIVE_PATH) != OK:
        return false
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT))
    for entry in reader.get_files():
        var clean := entry.replace("\\", "/")
        if clean.is_empty() or clean.begins_with("/") or clean.contains("../") or clean == ".." or clean.contains("/"):
            reader.close()
            return false
        if not clean.ends_with(".json"):
            reader.close()
            return false
        var output := FileAccess.open(ROOT + clean, FileAccess.WRITE)
        if output == null:
            reader.close()
            return false
        output.store_buffer(reader.read_file(entry))
        output.close()
    reader.close()
    return true

func _verify_extracted() -> bool:
    if not FileAccess.file_exists(MANIFEST_PATH):
        return false
    if FileAccess.get_sha256(MANIFEST_PATH).to_lower() != MANIFEST_SHA256:
        return false
    var parsed = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
    if not parsed is Dictionary or int(parsed.get("format_version", 0)) != 1 or str(parsed.get("pack_id", "")) != PACK_ID:
        return false
    if str(parsed.get("crs", "")) != "EPSG:3448" or absf(float(parsed.get("tile_size", 0.0)) - 4096.0) > 0.001:
        return false
    var policy: Dictionary = parsed.get("render_policy", {})
    if int(policy.get("max_active_tiles", 0)) > 9 or int(policy.get("max_vertices_per_tile", 0)) > 12000:
        return false
    var tiles: Array = parsed.get("tiles", [])
    if tiles.is_empty() or tiles.size() > 800:
        return false
    for raw in tiles:
        if not raw is Dictionary:
            return false
        var record: Dictionary = raw
        var filename := str(record.get("file", ""))
        if filename.is_empty() or filename.contains("/") or filename.contains("\\") or filename.contains("..") or not filename.ends_with(".json"):
            return false
        var path := ROOT + filename
        if not FileAccess.file_exists(path):
            return false
        var file := FileAccess.open(path, FileAccess.READ)
        if file == null or int(file.get_length()) != int(record.get("bytes", -1)):
            return false
        if FileAccess.get_sha256(path).to_lower() != str(record.get("sha256", "")).to_lower():
            return false
    return true

func _update_renderer() -> void:
    var game := get_tree().current_scene if get_tree() != null else null
    if game == null:
        return
    if game != _bound_game:
        if _renderer != null:
            _renderer.queue_free()
            _renderer = null
        _bound_game = game
    var roads = game.get("roads")
    var terrain = game.get("terrain")
    var car = game.get("car")
    if roads == null or terrain == null or not car is Node3D:
        return
    var coordinate_system = roads.get("coordinates")
    if coordinate_system == null:
        return
    if _renderer == null:
        _renderer = Renderer.new()
        _renderer.name = "JamaicaRunningWater"
        game.add_child(_renderer)
        if not _renderer.configure(ROOT, coordinate_system, terrain):
            _renderer.queue_free()
            _renderer = null
            return
    var world: PackedFloat64Array = coordinate_system.local_to_world((car as Node3D).position)
    if world.size() >= 3:
        _renderer.update_world(float(world[0]), float(world[2]))

func _emit_progress(downloaded: int) -> void:
    var clamped := clampi(downloaded, 0, PACK_BYTES)
    progress_changed.emit(clamped, PACK_BYTES)
    if _progress != null:
        _progress.value = float(clamped) * 100.0 / float(PACK_BYTES)
    if _state == "downloading" and _status != null:
        _status.text = "%s · %.2f / %.2f MB" % [_message, float(clamped) / 1048576.0, float(PACK_BYTES) / 1048576.0]

func _set_state(value: String, message: String) -> void:
    _state = value
    _message = message
    state_changed.emit(_state, _message)
    if _status != null:
        _status.text = message
    if _download_button != null:
        _download_button.disabled = value in ["downloading", "verifying", "installing"]
        if value == "installed":
            _download_button.text = "RUNNING WATER INSTALLED"
        elif value == "error":
            _download_button.text = "RETRY DOWNLOAD"
        else:
            _download_button.text = "DOWNLOAD RUNNING WATER"
    if _button != null:
        _button.text = "RIVERS · ON" if value == "installed" else "RIVERS"
