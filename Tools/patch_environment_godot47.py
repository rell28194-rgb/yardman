#!/usr/bin/env python3
from pathlib import Path

path = Path("godot/scripts/environment_content_runtime.gd")
text = path.read_text()

text = text.replace("    _http.keep_partial_download = true\n", "")

old_download = '''        _resume_offset = 0
        var part_path := final_path + ".part"
        var headers := PackedStringArray()
        if FileAccess.file_exists(part_path):
            var partial := FileAccess.open(part_path, FileAccess.READ)
            if partial != null:
                _resume_offset = int(partial.get_length())
            if _resume_offset <= 0 or _resume_offset >= expected_bytes:
                DirAccess.remove_absolute(ProjectSettings.globalize_path(part_path))
                _resume_offset = 0
            else:
                headers.append("Range: bytes=%d-" % _resume_offset)
        _http.download_file = part_path
        _http.append_to_download_file = _resume_offset > 0
        _set_state("downloading", "Downloading Environment HD · %s" % name)
        _emit_progress(_downloaded_total + _resume_offset)
        var err := _http.request(str(_current.url), headers)
'''
new_download = '''        _resume_offset = 0
        var part_path := final_path + ".part"
        if FileAccess.file_exists(part_path):
            DirAccess.remove_absolute(ProjectSettings.globalize_path(part_path))
        _http.download_file = part_path
        _set_state("downloading", "Downloading Environment HD · %s" % name)
        _emit_progress(_downloaded_total)
        var err := _http.request(str(_current.url))
'''
if old_download not in text:
    raise SystemExit("Environment HD download block changed; refusing blind patch")
text = text.replace(old_download, new_download)

old_finish = '''    if result != HTTPRequest.RESULT_SUCCESS or response_code not in [200, 206]:
        _set_state("error", "Environment asset download failed. Tap download to resume.")
        return
    if _resume_offset > 0 and response_code == 200:
        DirAccess.remove_absolute(ProjectSettings.globalize_path(part_path))
        _resume_offset = 0
        _queue.push_front(_current)
        _current = {}
        _start_next_asset()
        return
'''
new_finish = '''    if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
        _set_state("error", "Environment asset download failed. Tap download to retry.")
        return
'''
if old_finish not in text:
    raise SystemExit("Environment HD completion block changed; refusing blind patch")
text = text.replace(old_finish, new_finish)
text = text.replace("Tap download to resume.", "Tap download to retry.")

if "keep_partial_download" in text or "append_to_download_file" in text:
    raise SystemExit("unsupported Godot 4.7 HTTPRequest property remains")

path.write_text(text)
print("YARDMAN_ENVIRONMENT_GODOT47_PATCH_PASS")
