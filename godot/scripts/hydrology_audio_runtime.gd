extends Node3D
class_name YardmanHydrologyAudioRuntime

const SAMPLE_RATE := 22050
const UPDATE_INTERVAL := 0.20
const HEAR_DISTANCE_M := 130.0
const SILENT_DB := -80.0

var _voice: AudioStreamPlayer3D
var _clock := 0.0
var _last_distance := INF
var _last_sampled_segments := 0

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    _voice = AudioStreamPlayer3D.new()
    _voice.name = "NearestRunningWater"
    _voice.stream = build_water_stream()
    _voice.volume_db = SILENT_DB
    _voice.max_polyphony = 1
    _voice.max_distance = HEAR_DISTANCE_M
    _voice.unit_size = 8.0
    add_child(_voice)
    set_process(true)

func _exit_tree() -> void:
    if _voice != null:
        _voice.stop()
        _voice.stream = null

func _process(delta: float) -> void:
    _clock += clampf(delta, 0.0, 0.25) if is_finite(delta) else 0.016
    if _clock < UPDATE_INTERVAL:
        return
    _clock = 0.0
    _update_proximity_voice()

func _update_proximity_voice() -> void:
    var tree := get_tree()
    var game := tree.current_scene if tree != null else null
    var content := get_node_or_null("/root/HydrologyContent")
    if game == null or content == null or not content.has_method("get_state") or str(content.call("get_state")) != "installed":
        _silence()
        return
    if not bool(game.get("world_ready")):
        _silence()
        return
    var hud = game.get("hud")
    if hud != null and bool(hud.get("menu_open")):
        _silence()
        return
    var roads = game.get("roads")
    var terrain = game.get("terrain")
    var car = game.get("car")
    var player = game.get("player")
    if roads == null or terrain == null or not car is Node3D or not player is Node3D:
        _silence()
        return
    var coordinates = roads.get("coordinates")
    if coordinates == null:
        _silence()
        return
    var active: Node3D = car if bool(player.get("in_vehicle")) else player
    var world: PackedFloat64Array = coordinates.local_to_world(active.position)
    if world.size() < 3:
        _silence()
        return
    var renderer = content.get("_renderer")
    if renderer == null:
        _silence()
        return
    var geometry = renderer.get("_audio_geometry")
    if not geometry is Dictionary:
        _silence()
        return
    var info := nearest_info_from_geometry(geometry, Vector2(float(world[0]), float(world[2])), HEAR_DISTANCE_M)
    _last_sampled_segments = int(info.get("segments_checked", 0))
    if info.is_empty() or not is_finite(float(info.get("distance", INF))):
        _silence()
        return
    var distance := float(info.distance)
    _last_distance = distance
    if distance >= HEAR_DISTANCE_M:
        _silence()
        return
    var point: Vector2 = info.point
    var elevation := float(terrain.height_at(point.x, point.y))
    if not is_finite(elevation):
        elevation = float(world[1])
    position = coordinates.world_to_local(point.x, point.y, elevation + 0.15)
    var user_volume := 0.60
    var game_audio = game.get("game_audio")
    if game_audio != null:
        user_volume = clampf(float(game_audio.get("volume")), 0.0, 1.0)
    if user_volume <= 0.0001:
        _silence()
        return
    # 3D attenuation handles the actual spatial rolloff. This base level keeps
    # water subordinate to engine/footstep cues while still audible on foot.
    var near_strength := 1.0 - smoothstep(6.0, HEAR_DISTANCE_M, distance)
    _voice.volume_db = clampf(-25.0 + near_strength * 7.0 + linear_to_db(maxf(user_volume, 0.0001)), SILENT_DB, -15.0)
    _voice.pitch_scale = 0.94 + near_strength * 0.10
    if not _voice.playing:
        _voice.play()

func _silence() -> void:
    _last_distance = INF
    if _voice != null:
        _voice.volume_db = SILENT_DB
        if _voice.playing:
            _voice.stop()

func debug_state() -> Dictionary:
    return {
        "voices": 1 if _voice != null else 0,
        "playing": _voice.playing if _voice != null else false,
        "distance_m": _last_distance,
        "segments_checked": _last_sampled_segments,
        "max_distance_m": HEAR_DISTANCE_M,
    }

static func nearest_info_from_geometry(geometry: Dictionary, point: Vector2, max_distance: float) -> Dictionary:
    if not is_finite(point.x) or not is_finite(point.y) or not is_finite(max_distance) or max_distance <= 0.0:
        return {}
    var best := max_distance
    var best_point := Vector2.ZERO
    var checked := 0
    for raw in geometry.values():
        if not raw is Dictionary:
            continue
        var tile_data: Dictionary = raw
        var segments: PackedVector4Array = tile_data.get("segments", PackedVector4Array())
        var half_widths: PackedFloat32Array = tile_data.get("half_widths", PackedFloat32Array())
        var count := mini(segments.size(), half_widths.size())
        for index in range(count):
            checked += 1
            var segment := segments[index]
            var a := Vector2(segment.x, segment.y)
            var b := Vector2(segment.z, segment.w)
            var delta := b - a
            var t := clampf((point - a).dot(delta) / maxf(delta.length_squared(), 0.000001), 0.0, 1.0)
            var nearest := a + delta * t
            var edge_distance := maxf(0.0, point.distance_to(nearest) - float(half_widths[index]))
            if edge_distance < best:
                best = edge_distance
                best_point = nearest
    if best >= max_distance:
        return {}
    return {"distance": best, "point": best_point, "segments_checked": checked}

static func build_water_stream() -> AudioStreamWAV:
    # Integer-Hz harmonics complete whole cycles in the one-second loop, so
    # deterministic broadband water ambience loops without a seam or file IO.
    var frequencies := [73.0, 113.0, 181.0, 277.0, 421.0, 619.0, 887.0, 1259.0, 1747.0, 2381.0, 3181.0, 4027.0]
    var phases := [0.2, 1.1, 2.7, 0.7, 3.8, 1.9, 4.4, 2.2, 5.1, 3.0, 0.9, 4.9]
    var samples := SAMPLE_RATE + 1
    var pcm := PackedByteArray()
    pcm.resize(samples * 2)
    for index in range(samples):
        var t := float(index) / float(SAMPLE_RATE)
        var value := sin(TAU * 37.0 * t) * 0.055
        for harmonic in range(frequencies.size()):
            var weight := 0.13 / sqrt(float(harmonic) + 1.6)
            value += sin(TAU * frequencies[harmonic] * t + phases[harmonic]) * weight
        value *= 0.72 + 0.12 * sin(TAU * 3.0 * t) + 0.07 * sin(TAU * 7.0 * t + 0.8)
        pcm.encode_s16(index * 2, int(round(clampf(value, -0.82, 0.82) * 32767.0)))
    pcm.encode_s16((samples - 1) * 2, pcm.decode_s16(0))
    var stream := AudioStreamWAV.new()
    stream.format = AudioStreamWAV.FORMAT_16_BITS
    stream.mix_rate = SAMPLE_RATE
    stream.stereo = false
    stream.data = pcm
    stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
    stream.loop_begin = 0
    stream.loop_end = samples
    return stream
