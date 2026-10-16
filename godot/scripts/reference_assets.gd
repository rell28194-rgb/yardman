@static_unload
extends RefCounted
class_name YardmanReferenceAssets

const ROOT := "res://assets/user_reference/"
# These aliases are deliberate private-pack upgrades, not filename accidents.
# Callers keep stable semantic names while the best authorized recovered source
# can replace an older fallback without changing gameplay scripts.
const TEXTURE_UPGRADES := {
    "ground_grass.png": "beta2_ucaptain_scrub_grass_albedo.ktx",
    # The recovered mountain surface visibly contains vegetation and earth.
    # Keep exposed rock on its existing rock source instead of painting grass
    # across every steep cut/cliff through the rock semantic slot.
    "ground_dry_grass.png": "beta2_ucaptain_mountain_terrain_albedo.ktx",
    "ground_rock.png": "ground_rock_alternate.png",
}
# The original ground_rock.png contains snow. If its approved dry-rock
# replacement is absent, leave the shader's procedural rock active.
const STRICT_TEXTURE_UPGRADES := ["ground_rock.png"]
# Durable private-build recovery path. The owner Crown was already validated
# and exported successfully in run 38841581231. CI may recover the exact
# Godot-imported scene from that authenticated artifact when the temporary
# external source-pack URL has expired.
const RECOVERED_SCENE_CACHE := {
    "toyota_crown_2013.glb": {
        "path": "res://.godot/imported/toyota_crown_2013.glb-6ec01e928ae54ac12e5bc0f6ba8bd627.scn",
        "sha256": "7babf2e065a18e02f2fc215b011bcfea359851991c1f0700ea571e5c7365c385",
    },
}
static var _textures: Dictionary = {}
static var _scenes: Dictionary = {}

static func _valid_name(filename: String, extensions: PackedStringArray) -> bool:
    return not filename.is_empty() and not filename.contains("/") and not filename.contains("\\") \
        and not filename.contains("..") and filename.get_extension().to_lower() in extensions

static func _valid_sha256(value: String) -> bool:
    if value.length() != 64:
        return false
    for index in range(value.length()):
        if "0123456789abcdef".find(value.substr(index, 1)) < 0:
            return false
    return true

static func manifest_file_matches(filename: String, payload: Dictionary, actual_sha256: String = "", actual_size: int = -1) -> bool:
    # Private reference media are content-addressed by the pack manifest. A
    # duplicate path is ambiguous and therefore rejected rather than accepting
    # whichever record happens to appear first.
    if int(payload.get("format_version", 0)) != 1:
        return false
    var records = payload.get("files", [])
    if not records is Array:
        return false
    var matched: Dictionary = {}
    var match_count := 0
    for raw_record in records:
        if not raw_record is Dictionary:
            continue
        var record: Dictionary = raw_record
        if str(record.get("path", "")) != filename:
            continue
        match_count += 1
        matched = record
    if match_count != 1:
        return false
    var expected_sha := str(matched.get("sha256", "")).to_lower()
    if not _valid_sha256(expected_sha):
        return false
    if not actual_sha256.is_empty():
        var actual_sha := actual_sha256.to_lower()
        if not _valid_sha256(actual_sha) or actual_sha != expected_sha:
            return false
    if actual_size >= 0 and matched.has("bytes") and int(matched.get("bytes", -1)) != actual_size:
        return false
    return true

static func _media_matches_manifest(filename: String, path: String) -> bool:
    var payload := manifest()
    if payload.is_empty():
        return false
    # In editor/development runs the original source bytes are present, so
    # verify the exact content before importing it. Export templates may retain
    # only the imported resource/remap, so they enforce the manifest allowlist
    # while pre-export tests remain responsible for byte-for-byte verification.
    if not OS.has_feature("template"):
        if not FileAccess.file_exists(path):
            return false
        var handle := FileAccess.open(path, FileAccess.READ)
        if handle == null:
            return false
        var byte_count := int(handle.get_length())
        handle = null
        return manifest_file_matches(filename, payload, FileAccess.get_sha256(path), byte_count)
    return manifest_file_matches(filename, payload)

static func texture(filename: String) -> Texture2D:
    # KTX is accepted so owner-authorized source textures can preserve their
    # original GPU-compressed mip chain instead of being needlessly re-encoded.
    if not _valid_name(filename, PackedStringArray(["png", "jpg", "webp", "ktx"])):
        return null
    if _textures.has(filename):
        return _textures[filename] as Texture2D
    var candidates: Array[String] = []
    var upgraded := str(TEXTURE_UPGRADES.get(filename, ""))
    if not upgraded.is_empty():
        candidates.append(upgraded)
    if not filename in STRICT_TEXTURE_UPGRADES:
        candidates.append(filename)
    for candidate in candidates:
        var path := ROOT + candidate
        if not ResourceLoader.exists(path) or not _media_matches_manifest(candidate, path):
            continue
        var media := ResourceLoader.load(path) as Texture2D
        if media != null:
            _textures[filename] = media
            return media
    return null

static func scene(filename: String) -> PackedScene:
    if not _valid_name(filename, PackedStringArray(["glb", "gltf"])):
        return null
    if _scenes.has(filename):
        return _scenes[filename] as PackedScene
    var path := ROOT + filename
    if ResourceLoader.exists(path) and _media_matches_manifest(filename, path):
        var media := ResourceLoader.load(path) as PackedScene
        if media != null:
            _scenes[filename] = media
        return media

    # Source-pack URLs are intentionally not a permanent dependency of owner
    # builds. If the exact verified import cache has been recovered from the
    # prior successful private APK artifact, accept only the pinned cache hash
    # and the same manifest identity; never fall through to a different car.
    var recovery = RECOVERED_SCENE_CACHE.get(filename, {})
    if recovery is Dictionary and not recovery.is_empty():
        var recovered_path := str(recovery.get("path", ""))
        var expected_hash := str(recovery.get("sha256", "")).to_lower()
        var payload := manifest()
        if ResourceLoader.exists(recovered_path) and FileAccess.file_exists(recovered_path) \
                and _valid_sha256(expected_hash) \
                and FileAccess.get_sha256(recovered_path).to_lower() == expected_hash \
                and manifest_file_matches(filename, payload):
            var recovered := ResourceLoader.load(recovered_path) as PackedScene
            if recovered != null:
                _scenes[filename] = recovered
                return recovered

    if ResourceLoader.exists(path):
        push_warning("Yardman reference scene %s is not the manifest-verified private asset; refusing it" % filename)
    return null

static func audio(filename: String, loop: bool = false) -> AudioStream:
    if not _valid_name(filename, PackedStringArray(["wav", "ogg"])):
        return null
    var path := ROOT + filename
    if not ResourceLoader.exists(path) or not _media_matches_manifest(filename, path):
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
