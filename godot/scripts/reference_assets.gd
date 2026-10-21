@static_unload
extends RefCounted
class_name YardmanReferenceAssets

const ROOT := "res://assets/user_reference/"
const REMOTE_ROOT := "user://yardman/fleet64/"
const REMOTE_MARKER := "user://yardman/fleet64-installed.json"
const OPTIONAL_ROOTS: PackedStringArray = PackedStringArray([
    "user://yardman/packs/world-detail/",
    "user://yardman/packs/hydrology/",
    "user://yardman/packs/atmosphere/",
])
const SCENE_UPGRADES := {
    "road_car.glb": "toyota_crown_2013.glb",
}
const CROWN_CACHE_PATH := "res://.godot/imported/toyota_crown_2013.glb-6ec01e928ae54ac12e5bc0f6ba8bd627.scn"
static var _textures: Dictionary = {}
static var _scenes: Dictionary = {}
static var _verified_downloads: Dictionary = {}

static func _valid_name(filename: String, extensions: PackedStringArray) -> bool:
    return not filename.is_empty() and not filename.contains("/") and not filename.contains("\\") \
        and not filename.contains("..") and filename.get_extension().to_lower() in extensions

static func _remote_ready() -> bool:
    return FileAccess.file_exists(REMOTE_MARKER) and FileAccess.file_exists(REMOTE_ROOT + "manifest.json")

static func _read_manifest(path: String) -> Dictionary:
    if not FileAccess.file_exists(path):
        return {}
    var payload: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
    if payload is Dictionary and int((payload as Dictionary).get("format_version", 0)) == 1:
        return payload as Dictionary
    return {}

static func _manifest_record(filename: String, payload: Dictionary) -> Dictionary:
    if payload.is_empty():
        return {}
    var match: Dictionary = {}
    var count: int = 0
    for raw_record: Variant in payload.get("files", []):
        if not raw_record is Dictionary:
            continue
        var record: Dictionary = raw_record as Dictionary
        if str(record.get("path", "")) != filename:
            continue
        match = record
        count += 1
    return match if count == 1 else {}

static func _verify_downloaded_file(path: String, filename: String, payload: Dictionary) -> bool:
    if not FileAccess.file_exists(path):
        return false
    if bool(_verified_downloads.get(path, false)):
        return true
    var record: Dictionary = _manifest_record(filename, payload)
    if record.is_empty():
        return false
    var expected_sha: String = str(record.get("sha256", "")).to_lower()
    if expected_sha.length() != 64 or FileAccess.get_sha256(path).to_lower() != expected_sha:
        return false
    if record.has("bytes"):
        var handle: FileAccess = FileAccess.open(path, FileAccess.READ)
        if handle == null or int(handle.get_length()) != int(record.get("bytes", -1)):
            return false
    _verified_downloads[path] = true
    return true

static func exact_asset_path(filename: String) -> String:
    if not _valid_name(filename, PackedStringArray(["glb", "gltf", "png", "jpg", "jpeg", "webp", "wav", "ogg", "json"])):
        return ""
    var local: String = ROOT + filename
    if ResourceLoader.exists(local) or FileAccess.file_exists(local):
        return local
    if _remote_ready():
        var owner_manifest: Dictionary = _read_manifest(REMOTE_ROOT + "manifest.json")
        var downloaded: String = REMOTE_ROOT + filename
        if _verify_downloaded_file(downloaded, filename, owner_manifest):
            return downloaded
    for root: String in OPTIONAL_ROOTS:
        var path: String = root + filename
        if not FileAccess.file_exists(path):
            continue
        var pack_manifest: Dictionary = _read_manifest(root + "manifest.json")
        if pack_manifest.is_empty() or _verify_downloaded_file(path, filename, pack_manifest):
            return path
    return ""

static func exact_asset_exists(filename: String) -> bool:
    return not exact_asset_path(filename).is_empty()

static func texture(filename: String) -> Texture2D:
    if not _valid_name(filename, PackedStringArray(["png", "jpg", "jpeg", "webp"])):
        return null
    if _textures.has(filename):
        return _textures[filename] as Texture2D
    var path: String = exact_asset_path(filename)
    if path.is_empty():
        return null
    var media: Texture2D = null
    if path.begins_with("res://") and ResourceLoader.exists(path):
        media = ResourceLoader.load(path) as Texture2D
    else:
        var image := Image.new()
        var load_error: Error = image.load(ProjectSettings.globalize_path(path))
        if load_error == OK and not image.is_empty():
            media = ImageTexture.create_from_image(image)
    if media != null:
        _textures[filename] = media
    return media

static func _runtime_gltf_scene(path: String) -> PackedScene:
    var state := GLTFState.new()
    var document := GLTFDocument.new()
    var absolute_path: String = ProjectSettings.globalize_path(path)
    var err: Error = document.append_from_file(absolute_path, state, 0, absolute_path.get_base_dir())
    if err != OK:
        return null
    var generated: Node = document.generate_scene(state)
    if not generated is Node3D:
        if generated != null:
            generated.free()
        return null
    var packed := PackedScene.new()
    if packed.pack(generated) != OK:
        generated.free()
        return null
    generated.free()
    return packed

static func scene(filename: String) -> PackedScene:
    if not _valid_name(filename, PackedStringArray(["glb", "gltf"])):
        return null
    if _scenes.has(filename):
        return _scenes[filename] as PackedScene
    var resolved: String = str(SCENE_UPGRADES.get(filename, filename))
    var path: String = exact_asset_path(resolved)
    var media: PackedScene = null
    if not path.is_empty():
        if path.begins_with("res://") and ResourceLoader.exists(path):
            media = ResourceLoader.load(path) as PackedScene
        else:
            media = _runtime_gltf_scene(path)
    elif resolved == "toyota_crown_2013.glb" and ResourceLoader.exists(CROWN_CACHE_PATH):
        media = ResourceLoader.load(CROWN_CACHE_PATH) as PackedScene
    if media != null:
        _scenes[filename] = media
    return media

static func audio(filename: String, loop: bool = false) -> AudioStream:
    if not _valid_name(filename, PackedStringArray(["wav", "ogg"])):
        return null
    var path: String = ROOT + filename
    if not ResourceLoader.exists(path):
        return null
    var media: AudioStream = ResourceLoader.load(path) as AudioStream
    if loop and media is AudioStreamWAV:
        var looping_wav: AudioStreamWAV = media.duplicate() as AudioStreamWAV
        looping_wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
        looping_wav.loop_begin = 0
        looping_wav.loop_end = int(round(looping_wav.get_length() * looping_wav.mix_rate))
        return looping_wav
    if loop and media is AudioStreamOggVorbis:
        var looping_ogg: AudioStreamOggVorbis = media.duplicate() as AudioStreamOggVorbis
        looping_ogg.loop = true
        return looping_ogg
    return media

static func manifest() -> Dictionary:
    if _remote_ready():
        var remote: Dictionary = _read_manifest(REMOTE_ROOT + "manifest.json")
        if not remote.is_empty():
            return remote
    return _read_manifest(ROOT + "manifest.json")
