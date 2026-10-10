@static_unload
extends RefCounted
class_name YardmanReferenceAssets

const ROOT := "res://assets/user_reference/"
static var _textures: Dictionary = {}
static var _scenes: Dictionary = {}

static func _valid_name(filename: String, extensions: PackedStringArray) -> bool:
    return not filename.is_empty() and not filename.contains("/") and not filename.contains("\\") \
        and not filename.contains("..") and filename.get_extension().to_lower() in extensions

static func texture(filename: String) -> Texture2D:
    if not _valid_name(filename, PackedStringArray(["png", "jpg", "webp"])):
        return null
    if _textures.has(filename):
        return _textures[filename] as Texture2D
    var path := ROOT + filename
    if not ResourceLoader.exists(path):
        return null
    var media := ResourceLoader.load(path) as Texture2D
    if media != null:
        _textures[filename] = media
    return media

static func scene(filename: String) -> PackedScene:
    if not _valid_name(filename, PackedStringArray(["glb", "gltf"])):
        return null
    if _scenes.has(filename):
        return _scenes[filename] as PackedScene
    var path := ROOT + filename
    if not ResourceLoader.exists(path):
        return null
    var media := ResourceLoader.load(path) as PackedScene
    if media != null:
        _scenes[filename] = media
    return media

static func audio(filename: String, loop: bool = false) -> AudioStream:
    if not _valid_name(filename, PackedStringArray(["wav", "ogg"])):
        return null
    var path := ROOT + filename
    if not ResourceLoader.exists(path):
        return null
    var media := ResourceLoader.load(path) as AudioStream
    if loop and media is AudioStreamWAV:
        var looping := media.duplicate() as AudioStreamWAV
        looping.loop_mode = AudioStreamWAV.LOOP_FORWARD
        looping.loop_begin = 0
        looping.loop_end = int(round(looping.get_length() * looping.mix_rate))
        return looping
    if loop and media is AudioStreamOggVorbis:
        var looping := media.duplicate() as AudioStreamOggVorbis
        looping.loop = true
        return looping
    return media

static func manifest() -> Dictionary:
    var path := ROOT + "manifest.json"
    if not FileAccess.file_exists(path):
        return {}
    var payload = JSON.parse_string(FileAccess.get_file_as_string(path))
    return payload if payload is Dictionary and int(payload.get("format_version", 0)) == 1 else {}
