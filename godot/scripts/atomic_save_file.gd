extends RefCounted

# Install a fully written, validated sibling file. Domain readers own schema
# and checksum validation; this helper owns the shared replacement protocol.
static func commit_staged(temporary: String, path: String, read_valid: Callable) -> Error:
    var error := OK
    if FileAccess.file_exists(path):
        if not read_valid.call(path).is_empty():
            if FileAccess.file_exists(path + ".bak"):
                error = DirAccess.remove_absolute(path + ".bak")
                if error != OK:
                    return error
            error = DirAccess.rename_absolute(path, path + ".bak")
        else:
            # After recovery, .bak may be the only valid checkpoint. Replacing
            # a corrupt primary must preserve that backup throughout commit.
            error = DirAccess.remove_absolute(path)
        if error != OK:
            return error
    error = DirAccess.rename_absolute(temporary, path)
    if error != OK and not read_valid.call(path + ".bak").is_empty():
        DirAccess.rename_absolute(path + ".bak", path)
    return error
