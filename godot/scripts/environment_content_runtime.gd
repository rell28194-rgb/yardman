extends Node
class_name YardmanEnvironmentContentRuntime

signal state_changed(state: String, message: String)
signal progress_changed(downloaded_bytes: int, total_bytes: int)
signal installed

const PACK_ID := "environment_hd_android_v1"
const RELEASE_ROOT := "https://github.com/rell28194-rgb/yardman/releases/download/yardman-environment-v1"
const MANIFEST_URL := RELEASE_ROOT + "/yardman-environment-manifest.json"
const MANIFEST_SHA256 := "2bdbad8373f859821ec9c0422b10bbc86f410cd402b44db9d2afd5b794c54d24"
const ROOT := "user://yardman/content/environment_hd_android_v1/"
const MANIFEST_PATH := ROOT + "yardman-environment-manifest.json"
const MARKER_PATH := ROOT + "installed.json"
const UPDATE_INTERVAL := 0.45

const ROLE_HEIGHTS := {
    "grass_near": 0.55,
    "shrub_near": 1.15,
    "tree_near": 8.2,
}

var _http: HTTPRequest
var _state := "idle"
var _message := "Environment HD is optional."
var _mode := ""
var _manifest: Dictionary = {}
var _queue: Array[Dictionary] = []
var _current: Dictionary = {}
var _downloaded_total := 0
var _pack_total := 0
var _resume_offset := 0
var _last_progress_emit_msec := 0

var _layer: CanvasLayer
var _button: Button
var _panel: PanelContainer
var _status: Label
var _progress: ProgressBar
var _download_button: Button

var _meshes: Dictionary = {}
var _policies: Dictionary = {}
var _cells: Dictionary = {}
var _update_accumulator := 0.0

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
    get_tree().node_added.connect(_on_node_added)
    get_tree().node_removed.connect(_on_node_removed)
    set_process(true)
    if is_installed():
        _load_installed_manifest()
        _load_detail_meshes()
        _set_state("installed", "Environment HD installed · optimized near-field detail active.")
    else:
        _set_state("idle", "Environment HD available · Wi-Fi recommended · about 11 MB.")

func _process(delta: float) -> void:
    if _state == "downloading" and _http != null and not _current.is_empty():
        var now := Time.get_ticks_msec()
        if now - _last_progress_emit_msec >= 200:
            _last_progress_emit_msec = now
            var request_bytes: int = maxi(int(_http.get_downloaded_bytes()), 0)
            var downloaded: int = _downloaded_total + _resume_offset + request_bytes
            _emit_progress(downloaded)
    if _state != "installed" or _meshes.is_empty():
        return
    _update_accumulator += delta
    if _update_accumulator < UPDATE_INTERVAL:
        return
    _update_accumulator = 0.0
    _update_detail_cells()

func _build_ui() -> void:
    _layer = CanvasLayer.new()
    _layer.layer = 44
    add_child(_layer)

    _button = Button.new()
    _button.text = "CONTENT"
    _button.position = Vector2(18, 18)
    _button.size = Vector2(164, 46)
    _button.focus_mode = Control.FOCUS_NONE
    _button.pressed.connect(func() -> void: _panel.visible = not _panel.visible)
    _layer.add_child(_button)

    _panel = PanelContainer.new()
    _panel.position = Vector2(18, 72)
    _panel.size = Vector2(420, 245)
    _panel.visible = false
    _layer.add_child(_panel)

    var column := VBoxContainer.new()
    column.add_theme_constant_override("separation", 8)
    _panel.add_child(column)

    var title := Label.new()
    title.text = "OPTIONAL CONTENT"
    title.add_theme_font_size_override("font_size", 19)
    column.add_child(title)

    var pack := Label.new()
    pack.text = "Environment HD · grass / shrubs / island trees"
    pack.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    column.add_child(pack)

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
    _download_button.text = "DOWNLOAD HD DETAIL"
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
    attribution.text = "Environment HD source assets: Poly Haven · CC0"
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
    if not marker is Dictionary or str(marker.get("pack_id", "")) != PACK_ID:
        return false
    var parsed = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
    if not parsed is Dictionary or str(parsed.get("pack_id", "")) != PACK_ID:
        return false
    for raw_record in parsed.get("files", []):
        if not raw_record is Dictionary:
            return false
        var record: Dictionary = raw_record
        var name := str(record.get("name", ""))
        if not _safe_filename(name):
            return false
        var path := ROOT + name
        if not FileAccess.file_exists(path):
            return false
        var file := FileAccess.open(path, FileAccess.READ)
        if file == null or int(file.get_length()) != int(record.get("bytes", -1)):
            return false
    return true

func start_download() -> void:
    if _state in ["manifest", "downloading", "verifying", "installing"]:
        return
    if is_installed():
        _load_installed_manifest()
        _load_detail_meshes()
        _set_state("installed", "Environment HD already installed.")
        installed.emit()
        return
    _queue.clear()
    _current.clear()
    _downloaded_total = 0
    _pack_total = 0
    _mode = "manifest"
    _set_state("manifest", "Checking Environment HD package…")
    var err := _http.request(MANIFEST_URL)
    if err != OK:
        _set_state("error", "Could not reach Environment HD manifest (%s)." % error_string(err))

func cancel_download() -> void:
    if _state in ["manifest", "downloading"] and _http != null:
        _http.cancel_request()
        _set_state("idle", "Environment HD download paused. Tap download to retry.")

func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
    if _mode == "manifest":
        _finish_manifest_request(result, response_code, body)
        return
    if _mode == "asset":
        _finish_asset_request(result, response_code)

func _finish_manifest_request(result: int, response_code: int, body: PackedByteArray) -> void:
    if result != HTTPRequest.RESULT_SUCCESS or response_code != 200 or body.is_empty():
        _set_state("error", "Environment manifest download failed.")
        return
    var context := HashingContext.new()
    if context.start(HashingContext.HASH_SHA256) != OK:
        _set_state("error", "Environment manifest verifier could not start.")
        return
    context.update(body)
    if context.finish().hex_encode().to_lower() != MANIFEST_SHA256:
        _set_state("error", "Environment manifest verification failed.")
        return
    var parsed = JSON.parse_string(body.get_string_from_utf8())
    if not parsed is Dictionary or int(parsed.get("format_version", 0)) != 1 or str(parsed.get("pack_id", "")) != PACK_ID:
        _set_state("error", "Environment manifest is invalid.")
        return
    _manifest = parsed
    _queue.clear()
    _pack_total = 0
    for raw_record in _manifest.get("files", []):
        if not raw_record is Dictionary:
            _set_state("error", "Environment manifest contains an invalid file record.")
            return
        var record: Dictionary = raw_record.duplicate(true)
        var name := str(record.get("name", ""))
        var digest := str(record.get("sha256", "")).to_lower()
        var bytes := int(record.get("bytes", 0))
        if not _safe_filename(name) or digest.length() != 64 or bytes <= 0:
            _set_state("error", "Environment manifest contains unsafe file metadata.")
            return
        record["url"] = RELEASE_ROOT + "/" + name
        _queue.append(record)
        _pack_total += bytes
    if _queue.is_empty() or _pack_total > 96_000_000:
        _set_state("error", "Environment pack violates the Android resident-asset budget.")
        return
    var manifest_file := FileAccess.open(MANIFEST_PATH, FileAccess.WRITE)
    if manifest_file == null:
        _set_state("error", "Could not save Environment HD manifest.")
        return
    manifest_file.store_buffer(body)
    manifest_file.close()
    _downloaded_total = 0
    _mode = "asset"
    _start_next_asset()

func _start_next_asset() -> void:
    while not _queue.is_empty():
        _current = _queue.pop_front()
        var name := str(_current.name)
        var final_path := ROOT + name
        var expected_bytes := int(_current.bytes)
        if FileAccess.file_exists(final_path):
            var final_file := FileAccess.open(final_path, FileAccess.READ)
            if final_file != null and int(final_file.get_length()) == expected_bytes and FileAccess.get_sha256(final_path).to_lower() == str(_current.sha256).to_lower():
                _downloaded_total += expected_bytes
                _emit_progress(_downloaded_total)
                continue
            DirAccess.remove_absolute(ProjectSettings.globalize_path(final_path))
        _resume_offset = 0
        var part_path := final_path + ".part"
        if FileAccess.file_exists(part_path):
            DirAccess.remove_absolute(ProjectSettings.globalize_path(part_path))
        _http.download_file = part_path
        _set_state("downloading", "Downloading Environment HD · %s" % name)
        _emit_progress(_downloaded_total)
        var err := _http.request(str(_current.url))
        if err != OK:
            _set_state("error", "Could not start Environment HD asset download (%s)." % error_string(err))
        return
    _finish_install()

func _finish_asset_request(result: int, response_code: int) -> void:
    if _current.is_empty():
        _set_state("error", "Environment download lost its active file record.")
        return
    var final_path := ROOT + str(_current.name)
    var part_path := final_path + ".part"
    if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
        _set_state("error", "Environment asset download failed. Tap download to retry.")
        return
    var handle := FileAccess.open(part_path, FileAccess.READ)
    var size: int = int(handle.get_length()) if handle != null else -1
    var expected_bytes := int(_current.bytes)
    if size != expected_bytes:
        _set_state("error", "Environment asset is incomplete (%d / %d bytes). Tap download to retry." % [maxi(size, 0), expected_bytes])
        return
    _set_state("verifying", "Verifying Environment HD asset…")
    if FileAccess.get_sha256(part_path).to_lower() != str(_current.sha256).to_lower():
        DirAccess.remove_absolute(ProjectSettings.globalize_path(part_path))
        _set_state("error", "Environment asset verification failed. Bad data was discarded.")
        return
    if FileAccess.file_exists(final_path):
        DirAccess.remove_absolute(ProjectSettings.globalize_path(final_path))
    if DirAccess.rename_absolute(ProjectSettings.globalize_path(part_path), ProjectSettings.globalize_path(final_path)) != OK:
        _set_state("error", "Environment asset could not be installed.")
        return
    _downloaded_total += expected_bytes
    _emit_progress(_downloaded_total)
    _current = {}
    _resume_offset = 0
    _start_next_asset()

func _finish_install() -> void:
    _set_state("installing", "Activating optimized Environment HD detail…")
    var marker := FileAccess.open(MARKER_PATH, FileAccess.WRITE)
    if marker == null:
        _set_state("error", "Could not save Environment HD installation state.")
        return
    marker.store_string(JSON.stringify({
        "pack_id": PACK_ID,
        "manifest_sha256": MANIFEST_SHA256,
        "installed_at_unix": int(Time.get_unix_time_from_system()),
        "verified_bytes": _pack_total,
    }))
    marker.close()
    _load_installed_manifest()
    _load_detail_meshes()
    if _meshes.is_empty():
        _set_state("error", "Environment HD installed, but Godot could not load its detail meshes.")
        return
    _set_state("installed", "Environment HD installed · optimized near-field detail active.")
    _emit_progress(_pack_total)
    installed.emit()

func _load_installed_manifest() -> void:
    _manifest = {}
    _policies.clear()
    if not FileAccess.file_exists(MANIFEST_PATH):
        return
    var parsed = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
    if not parsed is Dictionary or str(parsed.get("pack_id", "")) != PACK_ID:
        return
    _manifest = parsed
    for raw_record in _manifest.get("files", []):
        if raw_record is Dictionary:
            var role := str(raw_record.get("role", ""))
            if ROLE_HEIGHTS.has(role):
                _policies[role] = raw_record

func _load_detail_meshes() -> void:
    _meshes.clear()
    for role in ROLE_HEIGHTS.keys():
        if not _policies.has(role):
            continue
        var record: Dictionary = _policies[role]
        var path := ROOT + str(record.name)
        var mesh := _load_runtime_mesh(path, float(ROLE_HEIGHTS[role]))
        if mesh != null:
            _meshes[role] = mesh

func _load_runtime_mesh(path: String, target_height: float) -> ArrayMesh:
    if not FileAccess.file_exists(path):
        return null
    var document := GLTFDocument.new()
    var state := GLTFState.new()
    if document.append_from_file(path, state) != OK:
        return null
    var source := document.generate_scene(state)
    if source == null:
        return null
    var groups: Dictionary = {}
    _collect_surfaces(source, Transform3D.IDENTITY, groups)
    source.free()
    var combined := ArrayMesh.new()
    for group: Dictionary in groups.values():
        var surface: SurfaceTool = group.surface
        surface.index()
        surface.commit(combined)
        combined.surface_set_material(combined.get_surface_count() - 1, group.material)
    if combined.get_surface_count() == 0:
        return null
    var bounds := combined.get_aabb()
    if bounds.size.y < 0.02:
        return null
    var scale_value := target_height / bounds.size.y
    var center := bounds.position + bounds.size * 0.5
    var correction := Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * scale_value), Vector3(-center.x, -bounds.position.y, -center.z) * scale_value)
    var baked := ArrayMesh.new()
    for surface_index in range(combined.get_surface_count()):
        var surface := SurfaceTool.new()
        surface.begin(Mesh.PRIMITIVE_TRIANGLES)
        surface.append_from(combined, surface_index, correction)
        surface.index()
        surface.commit(baked)
        baked.surface_set_material(surface_index, combined.surface_get_material(surface_index))
    return baked

func _collect_surfaces(node: Node, parent_pose: Transform3D, groups: Dictionary) -> void:
    var pose := parent_pose
    if node is Node3D:
        pose = parent_pose * (node as Node3D).transform
    if node is MeshInstance3D:
        var instance := node as MeshInstance3D
        if instance.mesh != null:
            for surface_index in range(instance.mesh.get_surface_count()):
                var material: Material = instance.get_active_material(surface_index)
                var key := material.get_instance_id() if material != null else 0
                if not groups.has(key):
                    var surface := SurfaceTool.new()
                    surface.begin(Mesh.PRIMITIVE_TRIANGLES)
                    groups[key] = {"surface": surface, "material": material}
                var target: SurfaceTool = groups[key].surface
                target.append_from(instance.mesh, surface_index, pose)
    for child in node.get_children():
        _collect_surfaces(child, pose, groups)

func _on_node_added(node: Node) -> void:
    if not node is MultiMeshInstance3D:
        return
    var instance := node as MultiMeshInstance3D
    var role := _role_for_cell(instance)
    if role.is_empty() or instance.multimesh == null or instance.multimesh.mesh == null:
        return
    _cells[instance.get_instance_id()] = {
        "node": instance,
        "role": role,
        "original_mesh": instance.multimesh.mesh,
        "original_visible": instance.multimesh.visible_instance_count,
        "original_shadow": instance.cast_shadow,
        "hd": false,
    }

func _on_node_removed(node: Node) -> void:
    _cells.erase(node.get_instance_id())

func _role_for_cell(instance: MultiMeshInstance3D) -> String:
    var label := str(instance.name).to_lower()
    if label.ends_with("_grass"):
        return "grass_near"
    if "_shrub" in label and not label.ends_with("_distant"):
        return "shrub_near"
    if "_broadleaf" in label and not label.ends_with("_distant"):
        return "tree_near"
    return ""

func _update_detail_cells() -> void:
    var camera := get_viewport().get_camera_3d()
    if camera == null:
        return
    var camera_position := camera.global_position
    var candidates: Dictionary = {}
    var stale: Array[int] = []
    for raw_id in _cells.keys():
        var id := int(raw_id)
        var entry: Dictionary = _cells[id]
        var node = entry.node
        if not is_instance_valid(node) or not node is MultiMeshInstance3D:
            stale.append(id)
            continue
        var instance := node as MultiMeshInstance3D
        var role := str(entry.role)
        if not _meshes.has(role) or not _policies.has(role):
            _set_cell_hd(id, false, -1)
            continue
        var policy: Dictionary = _policies[role]
        var max_distance := float(policy.get("max_distance_m", 0.0))
        var distance := camera_position.distance_to(instance.global_position)
        if distance > max_distance:
            _set_cell_hd(id, false, -1)
            continue
        if not candidates.has(role):
            candidates[role] = []
        candidates[role].append({"id": id, "distance": distance})
    for id in stale:
        _cells.erase(id)
    for role in candidates.keys():
        var entries: Array = candidates[role]
        entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.distance) < float(b.distance))
        var remaining := int(_policies[role].get("max_active_instances", 0))
        for candidate: Dictionary in entries:
            var id := int(candidate.id)
            var entry: Dictionary = _cells[id]
            var instance := entry.node as MultiMeshInstance3D
            var count := instance.multimesh.instance_count
            var allowed := mini(count, maxi(remaining, 0))
            if allowed > 0:
                _set_cell_hd(id, true, allowed)
                remaining -= allowed
            else:
                _set_cell_hd(id, false, -1)

func _set_cell_hd(id: int, enabled: bool, visible_count: int) -> void:
    if not _cells.has(id):
        return
    var entry: Dictionary = _cells[id]
    var node = entry.node
    if not is_instance_valid(node) or not node is MultiMeshInstance3D:
        return
    var instance := node as MultiMeshInstance3D
    if instance.multimesh == null:
        return
    var role := str(entry.role)
    if enabled and _meshes.has(role):
        if not bool(entry.hd):
            entry["original_visible"] = instance.multimesh.visible_instance_count
            entry["original_shadow"] = instance.cast_shadow
        instance.multimesh.mesh = _meshes[role]
        instance.multimesh.visible_instance_count = visible_count
        instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if role == "tree_near" else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        entry["hd"] = true
    else:
        if bool(entry.hd):
            instance.multimesh.mesh = entry.original_mesh
            instance.multimesh.visible_instance_count = int(entry.original_visible)
            instance.cast_shadow = int(entry.original_shadow)
        entry["hd"] = false
    _cells[id] = entry

func _safe_filename(name: String) -> bool:
    return not name.is_empty() and not name.contains("/") and not name.contains("\\") and not name.contains("..") and name.get_extension().to_lower() == "glb"

func _emit_progress(downloaded: int) -> void:
    var total := maxi(_pack_total, 1)
    var clamped := clampi(downloaded, 0, total)
    progress_changed.emit(clamped, _pack_total)
    if _progress != null:
        _progress.value = float(clamped) * 100.0 / float(total)
    if _state == "downloading" and _status != null:
        _status.text = "%s · %.1f / %.1f MB" % [_message, float(clamped) / 1048576.0, float(_pack_total) / 1048576.0]

func _set_state(value: String, message: String) -> void:
    _state = value
    _message = message
    state_changed.emit(_state, _message)
    if _status != null:
        _status.text = message
    if _download_button != null:
        _download_button.disabled = value in ["manifest", "downloading", "verifying", "installing"]
        if value == "installed":
            _download_button.text = "ENVIRONMENT HD INSTALLED"
        elif value == "error":
            _download_button.text = "RETRY DOWNLOAD"
        else:
            _download_button.text = "DOWNLOAD HD DETAIL"
    if _button != null:
        _button.text = "CONTENT · HD" if value == "installed" else "CONTENT"
