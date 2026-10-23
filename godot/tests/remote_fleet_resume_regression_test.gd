extends SceneTree

const RemoteFleetRuntime = preload("res://scripts/remote_fleet_runtime.gd")
var failures := 0
var _archive_backup := ""
var _chunk_backup := ""

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if condition:
        return
    failures += 1
    push_error("REMOTE_FLEET_RESUME_REGRESSION: " + message)

func _write_bytes(path: String, size: int) -> bool:
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
    var handle := FileAccess.open(path, FileAccess.WRITE)
    if handle == null:
        return false
    var bytes := PackedByteArray()
    bytes.resize(size)
    handle.store_buffer(bytes)
    handle.close()
    return true

func _backup(path: String) -> String:
    if not FileAccess.file_exists(path):
        return ""
    var source := ProjectSettings.globalize_path(path)
    var backup := source + ".regression-backup"
    if FileAccess.file_exists(backup):
        return "BLOCKED"
    if DirAccess.rename_absolute(source, backup) != OK:
        return "BLOCKED"
    return backup

func _restore(path: String, backup: String) -> void:
    var target := ProjectSettings.globalize_path(path)
    if FileAccess.file_exists(target):
        DirAccess.remove_absolute(target)
    if not backup.is_empty() and backup != "BLOCKED" and FileAccess.file_exists(backup):
        DirAccess.rename_absolute(backup, target)

func _run() -> void:
    _archive_backup = _backup(RemoteFleetRuntime.ARCHIVE_PATH)
    _chunk_backup = _backup(RemoteFleetRuntime.CHUNK_PATH)
    if _archive_backup == "BLOCKED" or _chunk_backup == "BLOCKED":
        _check(false, "could not safely isolate existing downloader files")
        _finish()
        return

    var remote := RemoteFleetRuntime.new()

    var legacy_bytes := 220 * 1024
    _check(_write_bytes(RemoteFleetRuntime.ARCHIVE_PATH, legacy_bytes), "could not create legacy partial fixture")
    _check(int(remote.call("_normalized_partial_bytes")) == 0, "unaligned legacy partial was not rejected")
    _check(not FileAccess.file_exists(RemoteFleetRuntime.ARCHIVE_PATH), "unaligned legacy partial was not discarded")

    _check(_write_bytes(RemoteFleetRuntime.ARCHIVE_PATH, RemoteFleetRuntime.CHUNK_BYTES), "could not create aligned resume fixture")
    _check(int(remote.call("_normalized_partial_bytes")) == RemoteFleetRuntime.CHUNK_BYTES, "aligned 4 MB partial was not resumable")
    _check(FileAccess.file_exists(RemoteFleetRuntime.ARCHIVE_PATH), "aligned resume fixture was incorrectly discarded")

    remote.set("_state", "downloading")
    remote.set("_cancelled", false)
    remote.set("_current_start", RemoteFleetRuntime.CHUNK_BYTES)
    remote.set("_current_end", RemoteFleetRuntime.CHUNK_BYTES * 2 - 1)
    _check(_write_bytes(RemoteFleetRuntime.CHUNK_PATH, 1024), "could not create ignored-range fixture")
    remote.call("_on_request_completed", HTTPRequest.RESULT_SUCCESS, 200,
        PackedStringArray(["Content-Type: application/zip"]), PackedByteArray())
    _check(str(remote.call("get_state")) == "error", "HTTP 200 ignored-range resume was not rejected")
    _check(not FileAccess.file_exists(RemoteFleetRuntime.CHUNK_PATH), "ignored-range chunk was not discarded")
    _check(int(remote.call("_normalized_partial_bytes")) == RemoteFleetRuntime.CHUNK_BYTES, "saved aligned progress was lost after ignored-range rejection")

    remote.set("_state", "downloading")
    remote.set("_cancelled", false)
    remote.set("_current_start", RemoteFleetRuntime.CHUNK_BYTES)
    remote.set("_current_end", RemoteFleetRuntime.CHUNK_BYTES * 2 - 1)
    _check(_write_bytes(RemoteFleetRuntime.CHUNK_PATH, RemoteFleetRuntime.CHUNK_BYTES), "could not create invalid Content-Range fixture")
    remote.call("_on_request_completed", HTTPRequest.RESULT_SUCCESS, 206,
        PackedStringArray([
            "Content-Type: application/zip",
            "Content-Range: bytes 0-%d/%d" % [RemoteFleetRuntime.CHUNK_BYTES - 1, RemoteFleetRuntime.PACK_BYTES]
        ]), PackedByteArray())
    _check(str(remote.call("get_state")) == "error", "mismatched 206 Content-Range was not rejected")
    _check(not FileAccess.file_exists(RemoteFleetRuntime.CHUNK_PATH), "invalid-range chunk was not discarded")
    _check(int(remote.call("_normalized_partial_bytes")) == RemoteFleetRuntime.CHUNK_BYTES, "saved progress was lost after invalid Content-Range rejection")

    remote.set("_state", "downloading")
    remote.set("_cancelled", false)
    remote.set("_retry_count", RemoteFleetRuntime.MAX_RETRIES)
    remote.call("_schedule_retry", "Forced network failure.")
    _check(str(remote.call("get_state")) == "error", "retry budget did not terminate in a resumable error state")
    _check(int(remote.call("get_downloaded_bytes")) == RemoteFleetRuntime.CHUNK_BYTES, "retry exhaustion did not preserve committed progress")
    _check(str(remote.call("get_message")).contains("tap retry to resume"), "retry exhaustion message does not expose resume action")

    remote.free()
    _finish()

func _finish() -> void:
    _restore(RemoteFleetRuntime.ARCHIVE_PATH, _archive_backup)
    _restore(RemoteFleetRuntime.CHUNK_PATH, _chunk_backup)
    if failures == 0:
        print("YARDMAN_REMOTE_FLEET_RESUME_REGRESSION_PASS legacy_220kb_reset=1 aligned_4mb_resume=1 ignored_range_rejected=1 invalid_content_range_rejected=1 retry_budget=5 committed_progress_preserved=1")
        quit(0)
        return
    print("YARDMAN_REMOTE_FLEET_RESUME_REGRESSION_FAIL count=%d" % failures)
    quit(1)
