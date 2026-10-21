extends Node
class_name YardmanSurfaceContentRuntime

signal state_changed(state: String, message: String)
signal progress_changed(downloaded_bytes: int, total_bytes: int)
signal installed

const PACK_ID := "yardman_surface_hd_android_v1"
const RELEASE_ROOT := "https://github.com/rell28194-rgb/yardman/releases/download/yardman-surface-hd-v1"
const MANIFEST_URL := RELEASE_ROOT + "/yardman-surface-hd-v1-manifest.json"
const MANIFEST_SHA256 := "49c30d214eb7c372136b718c4c8222d76ae3c77bd2ad671aecbb2cd851da6a10"
const ROOT := "user://yardman/content/yardman_surface_hd_android_v1/"
const MANIFEST_PATH := ROOT + "yardman-surface-hd-v1-manifest.json"
const MARKER_PATH := ROOT + "installed.json"
const EXPECTED_TOTAL_BYTES := 1_438_240
const MAX_PACK_BYTES := 8_000_000
const EXPECTED_ROLES := [
    "ground_lush", "ground_dry", "ground_wet_soil", "ground_rock", "beach_sand", "road_gravel"
]

var _http: HTTPRequest
var _state := "idle"
var _message := "Surface HD is optional."
var _mode := ""
var _manifest: Dictionary = {}
var _queue: Array[Dictionary] = []
var _current: Dictionary = {}
var _pack_total := 0
var _downloaded_total := 0
var _textures: Dictionary = {}

var _layer: CanvasLayer
var _button: Button
var _panel: PanelContainer
var _status: Label
var _progress: ProgressBar
var _download_button: Button

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT))
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
    if is_installed():
        _load_installed_manifest()
        if _load_textures():
            _set_state("installed", "Surface HD installed · terrain / beach / gravel detail active.")
            call_deferred("_apply_to_current_scene")
        else:
            _set_state("error", "Surface HD files exist but could not be loaded safely.")
    else:
        _set_state("idle", "Surface HD available · about 1.4 MB.")

func _build_ui() -> void:
    _layer = CanvasLayer.new()
    _layer.layer = 42
    add_child(_layer)
    _button = Button.new()
    _button.text = "SURFACES"
    _button.position = Vector2(362, 18)
    _button.size = Vector2(164, 46)
    _button.focus_mode = Control.FOCUS_NONE
    _button.pressed.connect(func() -> void: _panel.visible = not _panel.visible)
    _layer.add_child(_button)

    _panel = PanelContainer.new()
    _panel.position = Vector2(362, 72)
    _panel.size = Vector2(430, 250)
    _panel.visible = false
    _layer.add_child(_panel)
    var column := VBoxContainer.new()
    column.add_theme_constant_override("separation", 8)
    _panel.add_child(column)
    var title := Label.new()
    title.text = "SURFACE HD"
    title.add_theme_font_size_override("font_size", 19)
    column.add_child(title)
    var detail := Label.new()
    detail.text = "Lush / dry / wet soil / rock / beach / gravel · 768 px mobile materials"
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
    _download_button.text = "DOWNLOAD SURFACE HD"
    _download_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _download_button.focus_mode = Control.FOCUS_NONE
    _download_button.pressed.connect(start_download)
    actions.add_child(_download_button)
    var close := Button.new()
    close.text = "CLOSE"
    close.focus_mode = Control.FOCUS_NONE
    close.pressed.connect(func() -> void: _panel.visible = false)
    actions.add_child(close)
    var credit := Label.new()
    credit.text = "Powered by Poly Haven · CC0"
    credit.add_theme_font_size_override("font_size", 12)
    column.add_child(credit)

func get_state() -> String:
    return _state

func get_message() -> String:
    return _message

func is_installed() -> bool:
    if not FileAccess.file_exists(MARKER_PATH) or not FileAccess.file_exists(MANIFEST_PATH):
        return false
    var marker = JSON.parse_string(FileAccess.get_file_as_string(MARKER_PATH))
    if not marker is Dictionary or str(marker.get("pack_id", "")) != PACK_ID:
        return false
    if str(marker.get("manifest_sha256", "")).to_lower() != MANIFEST_SHA256:
        return false
    var parsed = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
    if not _valid_manifest(parsed):
        return false
    for raw in parsed.get("files", []):
        var record: Dictionary = raw
        var path := ROOT + str(record.file)
        if not FileAccess.file_exists(path):
            return false
        var handle := FileAccess.open(path, FileAccess.READ)
        if handle == null or int(handle.get_length()) != int(record.bytes):
            return false
    return true

func start_download() -> void:
    if _state in ["manifest", "downloading", "verifying", "installing"]:
        return
    if is_installed():
        _load_installed_manifest()
        if _load_textures():
            _set_state("installed", "Surface HD already installed.")
            _apply_to_current_scene()
            installed.emit()
        return
    _queue.clear()
    _current.clear()
    _pack_total = 0
    _downloaded_total = 0
    _mode = "manifest"
    _set_state("manifest", "Checking Surface HD package…")
    var err := _http.request(MANIFEST_URL)
    if err != OK:
        _set_state("error", "Could not reach Surface HD manifest (%s)." % error_string(err))

func cancel_download() -> void:
    if _state in ["manifest", "downloading"] and _http != null:
        _http.cancel_request()
        _set_state("idle", "Surface HD download stopped. Tap download to retry.")

func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
    if _mode == "manifest":
        _finish_manifest(result, response_code, body)
    elif _mode == "asset":
        _finish_asset(result, response_code)

func _finish_manifest(result: int, response_code: int, body: PackedByteArray) -> void:
    if result != HTTPRequest.RESULT_SUCCESS or response_code != 200 or body.is_empty():
        _set_state("error", "Surface HD manifest download failed.")
        return
    var context := HashingContext.new()
    if context.start(HashingContext.HASH_SHA256) != OK:
        _set_state("error", "Surface HD verifier could not start.")
        return
    context.update(body)
    if context.finish().hex_encode().to_lower() != MANIFEST_SHA256:
        _set_state("error", "Surface HD manifest verification failed.")
        return
    var parsed = JSON.parse_string(body.get_string_from_utf8())
    if not _valid_manifest(parsed):
        _set_state("error", "Surface HD manifest contract is invalid.")
        return
    _manifest = parsed
    _queue.clear()
    _pack_total = 0
    for raw in _manifest.files:
        var record: Dictionary = raw.duplicate(true)
        record["url"] = RELEASE_ROOT + "/" + str(record.file)
        _queue.append(record)
        _pack_total += int(record.bytes)
    var manifest_file := FileAccess.open(MANIFEST_PATH, FileAccess.WRITE)
    if manifest_file == null:
        _set_state("error", "Could not save Surface HD manifest.")
        return
    manifest_file.store_buffer(body)
    manifest_file.close()
    _mode = "asset"
    _start_next_asset()

func _valid_manifest(parsed) -> bool:
    if not parsed is Dictionary:
        return false
    if int(parsed.get("format_version", 0)) != 1 or str(parsed.get("pack_id", "")) != PACK_ID:
        return false
    var files: Array = parsed.get("files", [])
    if files.size() != EXPECTED_ROLES.size():
        return false
    var roles: Dictionary = {}
    var total := 0
    for raw in files:
        if not raw is Dictionary:
            return false
        var record: Dictionary = raw
        var role := str(record.get("role", ""))
        var file := str(record.get("file", ""))
        var digest := str(record.get("sha256", "")).to_lower()
        var bytes := int(record.get("bytes", 0))
        if role not in EXPECTED_ROLES or not _safe_filename(file) or digest.length() != 64 or bytes <= 0:
            return false
        if int(record.get("width", 0)) != 768 or int(record.get("height", 0)) != 768:
            return false
        roles[role] = true
        total += bytes
    return roles.size() == EXPECTED_ROLES.size() and total == EXPECTED_TOTAL_BYTES and total <= MAX_PACK_BYTES

func _start_next_asset() -> void:
    while not _queue.is_empty():
        _current = _queue.pop_front()
        var final_path := ROOT + str(_current.file)
        var expected_bytes := int(_current.bytes)
        if FileAccess.file_exists(final_path):
            var handle := FileAccess.open(final_path, FileAccess.READ)
            if handle != null and int(handle.get_length()) == expected_bytes and FileAccess.get_sha256(final_path).to_lower() == str(_current.sha256).to_lower():
                _downloaded_total += expected_bytes
                _emit_progress(_downloaded_total)
                continue
            DirAccess.remove_absolute(ProjectSettings.globalize_path(final_path))
        var part_path := final_path + ".part"
        if FileAccess.file_exists(part_path):
            DirAccess.remove_absolute(ProjectSettings.globalize_path(part_path))
        _http.download_file = part_path
        _set_state("downloading", "Downloading Surface HD · %s" % str(_current.role))
        var err := _http.request(str(_current.url))
        if err != OK:
            _set_state("error", "Could not start Surface HD asset download (%s)." % error_string(err))
        return
    _finish_install()

func _finish_asset(result: int, response_code: int) -> void:
    if _current.is_empty():
        _set_state("error", "Surface HD lost its active asset record.")
        return
    var final_path := ROOT + str(_current.file)
    var part_path := final_path + ".part"
    if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
        _set_state("error", "Surface HD asset download failed. Tap download to retry.")
        return
    var handle := FileAccess.open(part_path, FileAccess.READ)
    var size := int(handle.get_length()) if handle != null else -1
    if size != int(_current.bytes):
        _set_state("error", "Surface HD asset is incomplete.")
        return
    _set_state("verifying", "Verifying Surface HD asset…")
    if FileAccess.get_sha256(part_path).to_lower() != str(_current.sha256).to_lower():
        DirAccess.remove_absolute(ProjectSettings.globalize_path(part_path))
        _set_state("error", "Surface HD verification failed. Bad data was discarded.")
        return
    if FileAccess.file_exists(final_path):
        DirAccess.remove_absolute(ProjectSettings.globalize_path(final_path))
    if DirAccess.rename_absolute(ProjectSettings.globalize_path(part_path), ProjectSettings.globalize_path(final_path)) != OK:
        _set_state("error", "Surface HD asset could not be installed.")
        return
    _downloaded_total += int(_current.bytes)
    _emit_progress(_downloaded_total)
    _current = {}
    _start_next_asset()

func _finish_install() -> void:
    _set_state("installing", "Activating Surface HD materials…")
    _load_installed_manifest()
    if not _load_textures():
        _set_state("error", "Surface HD textures could not be decoded.")
        return
    var marker := FileAccess.open(MARKER_PATH, FileAccess.WRITE)
    if marker == null:
        _set_state("error", "Could not save Surface HD installation state.")
        return
    marker.store_string(JSON.stringify({
        "pack_id": PACK_ID,
        "manifest_sha256": MANIFEST_SHA256,
        "verified_bytes": _pack_total,
        "installed_at_unix": int(Time.get_unix_time_from_system()),
    }))
    marker.close()
    _set_state("installed", "Surface HD installed · terrain / beach / gravel detail active.")
    _emit_progress(_pack_total)
    _apply_to_current_scene()
    installed.emit()

func _load_installed_manifest() -> void:
    _manifest = {}
    if FileAccess.file_exists(MANIFEST_PATH):
        var parsed = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
        if _valid_manifest(parsed):
            _manifest = parsed
            _pack_total = EXPECTED_TOTAL_BYTES

func _load_textures() -> bool:
    _textures.clear()
    if _manifest.is_empty():
        return false
    for raw in _manifest.files:
        var record: Dictionary = raw
        var texture := _load_texture_file(ROOT + str(record.file))
        if texture == null:
            _textures.clear()
            return false
        _textures[str(record.role)] = texture
    return _textures.size() == EXPECTED_ROLES.size()

func _load_texture_file(path: String) -> ImageTexture:
    var image := Image.new()
    if image.load(path) != OK or image.is_empty():
        return null
    if image.get_width() != 768 or image.get_height() != 768:
        return null
    if not image.has_mipmaps():
        image.generate_mipmaps()
    return ImageTexture.create_from_image(image)

func apply_terrain_material(material: ShaderMaterial) -> void:
    if material == null or _textures.is_empty():
        return
    material.set_shader_parameter("surface_hd_lush", _textures.get("ground_lush"))
    material.set_shader_parameter("surface_hd_dry", _textures.get("ground_dry"))
    material.set_shader_parameter("surface_hd_soil", _textures.get("ground_wet_soil"))
    material.set_shader_parameter("surface_hd_rock", _textures.get("ground_rock"))
    material.set_shader_parameter("has_surface_hd", true)

func apply_beach_material(material: ShaderMaterial) -> void:
    if material == null or not _textures.has("beach_sand"):
        return
    material.set_shader_parameter("surface_hd_sand", _textures.beach_sand)
    material.set_shader_parameter("has_surface_hd_sand", true)

func apply_road_material(material: ShaderMaterial) -> void:
    if material == null or not _textures.has("road_gravel"):
        return
    material.set_shader_parameter("surface_hd_gravel", _textures.road_gravel)
    material.set_shader_parameter("has_surface_hd_gravel", true)

func _apply_to_current_scene() -> void:
    if _textures.is_empty() or get_tree() == null or get_tree().current_scene == null:
        return
    _apply_node_materials(get_tree().current_scene)

func _apply_node_materials(node: Node) -> void:
    if node is MeshInstance3D:
        var instance := node as MeshInstance3D
        if instance.material_override is ShaderMaterial:
            _apply_shader_material(instance.material_override)
        if instance.mesh != null:
            for surface_index in range(instance.mesh.get_surface_count()):
                var material := instance.mesh.surface_get_material(surface_index)
                if material is ShaderMaterial:
                    _apply_shader_material(material)
    for child in node.get_children():
        _apply_node_materials(child)

func _apply_shader_material(material: ShaderMaterial) -> void:
    if material.shader == null:
        return
    match material.shader.resource_path:
        "res://shaders/terrain_surface.gdshader": apply_terrain_material(material)
        "res://shaders/beach.gdshader": apply_beach_material(material)
        "res://shaders/road_surface.gdshader": apply_road_material(material)

func _safe_filename(name: String) -> bool:
    return not name.is_empty() and not name.contains("/") and not name.contains("\\") and not name.contains("..") and name.get_extension().to_lower() == "jpg"

func _emit_progress(downloaded: int) -> void:
    var total := maxi(_pack_total, EXPECTED_TOTAL_BYTES)
    var clamped := clampi(downloaded, 0, total)
    progress_changed.emit(clamped, total)
    if _progress != null:
        _progress.value = float(clamped) * 100.0 / float(total)
    if _state == "downloading" and _status != null:
        _status.text = "%s · %.2f / %.2f MB" % [_message, float(clamped) / 1048576.0, float(total) / 1048576.0]

func _set_state(value: String, message: String) -> void:
    _state = value
    _message = message
    state_changed.emit(value, message)
    if _status != null:
        _status.text = message
    if _download_button != null:
        _download_button.disabled = value in ["manifest", "downloading", "verifying", "installing"]
        if value == "installed":
            _download_button.text = "SURFACE HD INSTALLED"
        elif value == "error":
            _download_button.text = "RETRY DOWNLOAD"
        else:
            _download_button.text = "DOWNLOAD SURFACE HD"
    if _button != null:
        _button.text = "SURFACES · HD" if value == "installed" else "SURFACES"
