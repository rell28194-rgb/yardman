@static_unload
extends RefCounted
class_name YardmanReferenceAssets

const ROOT := "res://assets/user_reference/"
const REMOTE_ROOT := "user://yardman/fleet64/"
const SCENE_UPGRADES := {
    "road_car.glb": "toyota_crown_2013.glb",
}
const CROWN_CACHE_PATH := "res://.godot/imported/toyota_crown_2013.glb-6ec01e928ae54ac12e5bc0f6ba8bd627.scn"
static var _textures: Dictionary = {}
static var _scenes: Dictionary = {}

static func _valid_name(filename: String, extensions: PackedStringArray) -> bool:
    return not filename.is_empty() and not filename.contains("/") and not filename.contains("\\") \
        and not filename.contains("..") and filename.get_extension().to_lower() in extensions

static func exact_asset_path(filename: String) -> String:
    if not _valid_name(filename, PackedStringArray(["glb", "gltf", "png", "jpg", "webp", "wav", "ogg", "json"])):
        return ""
    var local := ROOT + filename
    if ResourceLoader.exists(local) or FileAccess.file_exists(local):
        return local
    if filename == "toyota_crown_2013.glb" and ResourceLoader.exists(CROWN_CACHE_PATH):
        return CROWN_CACHE_PATH
    var downloaded := REMOTE_ROOT + filename
    if FileAccess.file_exists(downloaded):
        return downloaded
    return ""

static func exact_asset_exists(filename: String) -> bool:
    return not exact_asset_path(filename).is_empty()

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
    var resolved := str(SCENE_UPGRADES.get(filename, filename))
    var path := ROOT + resolved
    var media: PackedScene = null
    if ResourceLoader.exists(path):
        media = ResourceLoader.load(path) as PackedScene
    elif resolved == "toyota_crown_2013.glb" and ResourceLoader.exists(CROWN_CACHE_PATH):
        media = ResourceLoader.load(CROWN_CACHE_PATH) as PackedScene
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
    if media != null and loop and media is AudioStreamWAV:
        var looping := media.duplicate() as AudioStreamWAV
        looping.loop_mode = AudioStreamWAV.LOOP_FORWARD
        looping.loop_begin = 0
        looping.loop_end = int(round(looping.get_length() * looping.mix_rate))
        return looping
    if media != null and loop and media is AudioStreamOggVorbis:
        var looping := media.duplicate() as AudioStreamOggVorbis
        looping.loop = true
        return looping
    return media

static func manifest() -> Dictionary:
    for path in [REMOTE_ROOT + "manifest.json", ROOT + "manifest.json"]:
        if not FileAccess.file_exists(path):
            continue
        var payload = JSON.parse_string(FileAccess.get_file_as_string(path))
        if payload is Dictionary and int(payload.get("format_version", 0)) == 1:
            return payload
    return {}
