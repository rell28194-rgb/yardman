extends Node
class_name YardmanRemoteFleetRuntime

signal state_changed(state: String, message: String)
signal progress_changed(downloaded_bytes: int, total_bytes: int)
signal installed

const DEFAULT_PACK_URL := "https://www.dropbox.com/scl/fi/jv54iuqhthvejvuy6zezc/Yardman-Owner-Recovery-Private-Fleet-64-2026-10-19.zip?rlkey=80kgw28rol81hnia2xbikuspe&dl=1"
const PACK_URL_SETTING := "yardman/content/fleet64_url"
const PACK_SHA256 := "6b1130bcd9a6ab554c3134710b348050d1a03e40c6c3f16136fefbeda5c5e75b"
const PACK_BYTES := 159594070
const CHUNK_BYTES := 4 * 1024 * 1024
const MAX_RETRIES := 5
const ROOT := "user://yardman/fleet64/"
const ARCHIVE_PATH := "user://yardman/fleet64-download.zip.part"
const CHUNK_PATH := "user://yardman/fleet64-download.chunk"
const MARKER_PATH := "user://yardman/fleet64-installed.json"
const MANIFEST_PATH := ROOT + "manifest.json"

var _http: HTTPRequest
var _retry_timer: Timer
var _state := "idle"
var _message := "Vehicle pack not installed."
var _last_progress_emit_msec: int = 0
var _current_start: int = 0
var _current_end: int = -1
var _retry_count: int = 0
var _request_active := false
var _cancelled := false

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://yardman"))
    _http = HTTPRequest.new()
    _http.use_threads = true
    _http.accept_gzip = false
    _http.body_size_limit = -1
    _http.download_chunk_size = 262144
    _http.max_redirects = 8
    _http.timeout = 45.0
    _http.request_completed.connect(_on_request_completed)
    add_child(_http)
    _retry_timer = Timer.new()
    _retry_timer.one_shot = true
    _retry_timer.process_callback = Timer.TIMER_PROCESS_IDLE
    _retry_timer.timeout.connect(_request_next_chunk)
    add_child(_retry_timer)
    set_process(true)
    _clean_stale_chunk()
    if is_installed():
        _set_state("installed", "64-vehicle pack installed.")
    else:
        var partial := _normalized_partial_bytes()
        if partial > 0:
            _set_state("idle", "Vehicle pack paused at %s. Tap download to resume." % _format_bytes(partial))
        else:
            _set_state("idle", "Vehicle pack ready to download over Wi-Fi.")

func _process(_delta: float) -> void:
    if _state != "downloading" or _http == null:
        return
    var now: int = Time.get_ticks_msec()
    if now - _last_progress_emit_msec < 200:
        return
    _last_progress_emit_msec = now
    var base: int = _current_start if _request_active else _normalized_partial_bytes()
    var inflight: int = maxi(int(_http.get_downloaded_bytes()), 0) if _request_active else 0
    var expected: int = maxi(_current_end - _current_start + 1, 0)
    if expected > 0:
        inflight = mini(inflight, expected)
    progress_changed.emit(mini(base + inflight, PACK_BYTES), PACK_BYTES)

func get_state() -> String:
    return _state

func get_message() -> String:
    return _message

func get_downloaded_bytes() -> int:
    return _normalized_partial_bytes()

func is_installed() -> bool:
    if not FileAccess.file_exists(MARKER_PATH) or not FileAccess.file_exists(MANIFEST_PATH):
        return false
    var marker = JSON.parse_string(FileAccess.get_file_as_string(MARKER_PATH))
    if not marker is Dictionary:
        return false
    return str(marker.get("pack_sha256", "")).to_lower() == PACK_SHA256 and int(marker.get("pack_bytes", 0)) == PACK_BYTES

func start_download() -> bool:
    if is_installed():
        _set_state("installed", "64-vehicle pack already installed.")
        installed.emit()
        return true
    if _state in ["downloading", "verifying", "installing"]:
        return false
    _cancelled = false
    _retry_count = 0
    _clean_stale_chunk()
    var partial := _normalized_partial_bytes()
    _set_state("downloading", "Downloading vehicle pack… %s of %s saved." % [_format_bytes(partial), _format_bytes(PACK_BYTES)])
    progress_changed.emit(partial, PACK_BYTES)
    call_deferred("_request_next_chunk")
    return true

func cancel_download() -> void:
    if _state != "downloading":
        return
    _cancelled = true
    _request_active = false
    if _retry_timer != null:
        _retry_timer.stop()
    if _http != null:
        _http.cancel_request()
    _clean_stale_chunk()
    var partial := _normalized_partial_bytes()
    _set_state("idle", "Vehicle download paused at %s. Progress is saved." % _format_bytes(partial))
    progress_changed.emit(partial, PACK_BYTES)

func _request_next_chunk() -> void:
    if _cancelled or _state != "downloading" or _request_active:
        return
    var partial := _normalized_partial_bytes()
    if partial == PACK_BYTES:
        _verify_and_install()
        return
    _current_start = partial
    _current_end = mini(_current_start + CHUNK_BYTES - 1, PACK_BYTES - 1)
    _clean_stale_chunk()
    _http.download_file = CHUNK_PATH
    var headers := PackedStringArray([
        "Range: bytes=%d-%d" % [_current_start, _current_end],
        "Accept: application/octet-stream, application/zip",
        "Accept-Encoding: identity",
        "Cache-Control: no-transform"
    ])
    _request_active = true
    var err := _http.request(_pack_url(), headers, HTTPClient.METHOD_GET)
    if err != OK:
        _request_active = false
        _schedule_retry("Could not start vehicle download (%s)." % error_string(err))

func _on_request_completed(result: int, response_code: int, headers: PackedStringArray, _body: PackedByteArray) -> void:
    _request_active = false
    if _cancelled or _state != "downloading":
        _clean_stale_chunk()
        return
    if result != HTTPRequest.RESULT_SUCCESS:
        _schedule_retry("Vehicle download was interrupted.")
        return
    if response_code in [408, 425, 429, 500, 502, 503, 504]:
        _schedule_retry("Vehicle source returned HTTP %d." % response_code)
        return
    if response_code not in [200, 206]:
        _clean_stale_chunk()
        _set_state("error", "Vehicle source rejected the request (HTTP %d). Saved progress was kept." % response_code)
        return

    var content_type := _header_value(headers, "content-type").to_lower()
    if content_type.contains("text/html") or content_type.contains("text/plain") or content_type.contains("application/json") or content_type.contains("xml"):
        _clean_stale_chunk()
        _set_state("error", "Vehicle source returned a webpage/error instead of the pack. Saved progress was kept.")
        return
    if not FileAccess.file_exists(CHUNK_PATH):
        _schedule_retry("Vehicle source returned no downloadable data.")
        return

    var chunk_size := _file_size(CHUNK_PATH)
    var expected_size := _current_end - _current_start + 1
    if response_code == 206:
        var content_range := _header_value(headers, "content-range").to_lower()
        var expected_prefix := "bytes %d-%d/" % [_current_start, _current_end]
        if content_range.is_empty() or not content_range.begins_with(expected_prefix) or not content_range.ends_with("/%d" % PACK_BYTES):
            _clean_stale_chunk()
            _set_state("error", "Vehicle source returned an invalid byte range. Saved progress was kept.")
            return
        if chunk_size != expected_size:
            _schedule_retry("Vehicle chunk was incomplete (%d / %d bytes)." % [maxi(chunk_size, 0), expected_size])
            return
    else:
        # A server may ignore Range only for the first request. Accept that path
        # solely when it returned the complete, exact pack in one response.
        if _current_start != 0 or chunk_size != PACK_BYTES:
            _clean_stale_chunk()
            _set_state("error", "Vehicle source ignored resumable byte ranges or returned incomplete data (%d bytes)." % maxi(chunk_size, 0))
            return

    if not _append_chunk(CHUNK_PATH):
        _clean_stale_chunk()
        _set_state("error", "Could not save downloaded vehicle data. Check free storage.")
        return
    _clean_stale_chunk()
    _retry_count = 0
    var saved := _normalized_partial_bytes()
    progress_changed.emit(saved, PACK_BYTES)
    if saved == PACK_BYTES:
        _verify_and_install()
    else:
        _set_state("downloading", "Downloading vehicle pack… %s of %s saved." % [_format_bytes(saved), _format_bytes(PACK_BYTES)])
        call_deferred("_request_next_chunk")

func _schedule_retry(reason: String) -> void:
    _request_active = false
    _clean_stale_chunk()
    if _cancelled or _state != "downloading":
        return
    _retry_count += 1
    if _retry_count > MAX_RETRIES:
        var saved := _normalized_partial_bytes()
        _set_state("error", "%s Download paused at %s; tap retry to resume." % [reason, _format_bytes(saved)])
        progress_changed.emit(saved, PACK_BYTES)
        return
    var delay := minf(pow(2.0, float(_retry_count - 1)), 30.0)
    var saved := _normalized_partial_bytes()
    _set_state("downloading", "%s Retrying in %.0fs; %s already saved." % [reason, delay, _format_bytes(saved)])
    _retry_timer.start(delay)

func _verify_and_install() -> void:
    if _state not in ["downloading", "verifying"]:
        return
    var size := _file_size(ARCHIVE_PATH)
    if size != PACK_BYTES:
        _set_state("error", "Vehicle download is incomplete (%d / %d bytes). Saved progress was kept." % [maxi(size, 0), PACK_BYTES])
        return
    _set_state("verifying", "Verifying vehicle pack…")
    progress_changed.emit(PACK_BYTES, PACK_BYTES)
    var digest := FileAccess.get_sha256(ARCHIVE_PATH).to_lower()
    if digest != PACK_SHA256:
        _remove_file(ARCHIVE_PATH)
        _set_state("error", "Vehicle pack verification failed. Corrupt bytes were discarded; retry starts clean.")
        progress_changed.emit(0, PACK_BYTES)
        return
    _set_state("installing", "Installing vehicles…")
    if not _extract_archive():
        _set_state("error", "Vehicle pack could not be installed. Verified archive was kept for retry.")
        return
    if not FileAccess.file_exists(MANIFEST_PATH):
        _set_state("error", "Vehicle pack manifest is missing after install. Verified archive was kept.")
        return
    var marker_file := FileAccess.open(MARKER_PATH, FileAccess.WRITE)
    if marker_file == null:
        _set_state("error", "Could not save vehicle installation state. Verified archive was kept.")
        return
    marker_file.store_string(JSON.stringify({
        "pack_sha256": PACK_SHA256,
        "pack_bytes": PACK_BYTES,
        "installed_at_unix": int(Time.get_unix_time_from_system())
    }))
    marker_file.close()
    _remove_file(ARCHIVE_PATH)
    _set_state("installed", "64-vehicle pack installed.")
    progress_changed.emit(PACK_BYTES, PACK_BYTES)
    installed.emit()

func _normalized_partial_bytes() -> int:
    if not FileAccess.file_exists(ARCHIVE_PATH):
        return 0
    var size := _file_size(ARCHIVE_PATH)
    if size < 0 or size > PACK_BYTES:
        _remove_file(ARCHIVE_PATH)
        return 0
    if size == PACK_BYTES:
        return size
    # Only complete chunks are committed to the archive. Any non-aligned
    # partial came from the legacy one-shot downloader or an interrupted write.
    if size % CHUNK_BYTES != 0:
        _remove_file(ARCHIVE_PATH)
        return 0
    return size

func _append_chunk(path: String) -> bool:
    var source := FileAccess.open(path, FileAccess.READ)
    if source == null:
        return false
    var bytes := source.get_buffer(source.get_length())
    source.close()
    var target: FileAccess
    if FileAccess.file_exists(ARCHIVE_PATH):
        target = FileAccess.open(ARCHIVE_PATH, FileAccess.READ_WRITE)
        if target != null:
            target.seek_end()
    else:
        target = FileAccess.open(ARCHIVE_PATH, FileAccess.WRITE)
    if target == null:
        return false
    target.store_buffer(bytes)
    target.close()
    return true

func _extract_archive() -> bool:
    var reader := ZIPReader.new()
    if reader.open(ARCHIVE_PATH) != OK:
        return false
    var root_abs := ProjectSettings.globalize_path(ROOT)
    DirAccess.make_dir_recursive_absolute(root_abs)
    for entry in reader.get_files():
        var clean := entry.replace("\\", "/")
        if clean.is_empty() or clean.begins_with("/") or clean.contains("../") or clean == "..":
            reader.close()
            return false
        if clean.ends_with("/"):
            DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT + clean))
            continue
        var target := ROOT + clean
        DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(target.get_base_dir()))
        var output := FileAccess.open(target, FileAccess.WRITE)
        if output == null:
            reader.close()
            return false
        var bytes := reader.read_file(entry)
        output.store_buffer(bytes)
        output.close()
    reader.close()
    return true

func _pack_url() -> String:
    var configured := str(ProjectSettings.get_setting(PACK_URL_SETTING, DEFAULT_PACK_URL)).strip_edges()
    return configured if not configured.is_empty() else DEFAULT_PACK_URL

func _header_value(headers: PackedStringArray, key: String) -> String:
    var prefix := key.to_lower() + ":"
    for header in headers:
        var lowered := header.to_lower()
        if lowered.begins_with(prefix):
            return header.substr(prefix.length()).strip_edges()
    return ""

func _file_size(path: String) -> int:
    var handle := FileAccess.open(path, FileAccess.READ)
    if handle == null:
        return -1
    var size := int(handle.get_length())
    handle.close()
    return size

func _clean_stale_chunk() -> void:
    _remove_file(CHUNK_PATH)

func _remove_file(path: String) -> void:
    if FileAccess.file_exists(path):
        DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

func _format_bytes(value: int) -> String:
    var amount := float(maxi(value, 0))
    if amount >= 1024.0 * 1024.0:
        return "%.1f MB" % (amount / (1024.0 * 1024.0))
    if amount >= 1024.0:
        return "%.1f KB" % (amount / 1024.0)
    return "%d B" % int(amount)

func _set_state(value: String, message: String) -> void:
    _state = value
    _message = message
    state_changed.emit(_state, _message)
