@static_unload
extends Node
class_name YardmanGameAudio

# Owner-supplied samples replace cached fallback PCM in personal builds.
# Surface variants share the existing four AudioStreamPlayer voices: recovered
# media improves timbre without reopening the old voice-budget overflow path.
const References = preload("res://scripts/reference_assets.gd")
const SAMPLE_RATE := 22050
const SILENT_DB := -80.0
const OPTIONAL_AUDIO_FILES := {
    "engine_drive": "engine_drive_loop.wav",
    "road_gravel": "gravel_skid_loop.wav",
    "road_grass": "grass_roll_loop.wav",
    "road_skid": "tire_skid_loop.wav",
    "footstep_one_shot": "footsteps.wav",
}
static var _stream_cache: Dictionary = {}
static var _cache_build_count := 0
static var _active_instances := 0
static var _footstep_one_shot_available := false

var engine: AudioStreamPlayer
var road_roll: AudioStreamPlayer
var footsteps: AudioStreamPlayer
var wind: AudioStreamPlayer
var quality := "Balanced"
var volume := 0.60
var _voices: Array[AudioStreamPlayer] = []
var _configured := false
var _rpm := 900.0
var _load := 0.0
var _previous_speed := 0.0
var _last_driving := false
var _engine_stream_key := "engine"
var _road_stream_key := "road"
var _surface_probe_clock := 0.0
var _surface_hint := "offroad"
var _step_clock := 0.0
var _step_index := 0

func _ready() -> void:
    if not _configured:
        configure()

func configure(profile: String = "Balanced", default_volume: float = 0.60) -> void:
    quality = profile
    if not _configured:
        _prepare_streams()
        engine = _make_voice("Engine", _stream_cache.engine)
        road_roll = _make_voice("RoadRoll", _stream_cache.road)
        footsteps = _make_voice("Footsteps", _stream_cache.footstep_one_shot if _footstep_one_shot_available else _stream_cache.footsteps)
        wind = _make_voice("Wind", _stream_cache.wind)
        _configured = true
        _active_instances += 1
    set_volume(default_volume)

func _exit_tree() -> void:
    _silence()
    for player in _voices:
        player.stream = null
    if _configured:
        _active_instances = maxi(0, _active_instances - 1)
        _configured = false
    if _active_instances == 0:
        _stream_cache.clear()
        _cache_build_count = 0
        _footstep_one_shot_available = false

func set_volume(value: float) -> void:
    volume = clampf(value, 0.0, 1.0) if is_finite(value) else 0.0
    if volume <= 0.0001:
        _silence()

func update_state(delta: float, state: Dictionary) -> void:
    if not _configured:
        configure(quality, volume)
    var dt := clampf(delta, 0.001, 0.20) if is_finite(delta) else 0.016
    var active := bool(state.get("ready", false)) and not bool(state.get("menu_open", false))
    var driving := bool(state.get("driving", false))
    var speed := _finite_value(state.get("speed_mps", 0.0), -100.0, 100.0)
    var walk_speed := absf(_finite_value(state.get("walk_speed", 0.0), 0.0, 15.0))
    var desired_rpm := _finite_value(state.get("rpm", 900.0), 0.0, 7000.0)
    var acceleration := (absf(speed) - absf(_previous_speed)) / dt if _last_driving and driving else 0.0
    var desired_load := clampf(0.12 + maxf(acceleration, 0.0) / 7.0, 0.0, 1.0)
    if state.has("throttle"):
        desired_load = absf(_finite_value(state.throttle, -1.0, 1.0))
    var braking := absf(_finite_value(state.get("brake", clampf(-acceleration / 8.5, 0.0, 1.0)), 0.0, 1.0))
    var surface := _resolve_surface(state, dt)
    _rpm = lerpf(_rpm, desired_rpm, 1.0 - exp(-dt * 6.0))
    _load = lerpf(_load, desired_load, 1.0 - exp(-dt * 7.0))
    _previous_speed = speed
    _last_driving = driving
    if not active or volume <= 0.0001:
        _silence()
        return

    _engine_stream_key = engine_stream_key(absf(speed), _load, _rpm)
    _road_stream_key = road_stream_key(surface, braking, absf(speed))
    _route_stream(engine, _engine_stream_key)
    _route_stream(road_roll, _road_stream_key)

    var speed_fraction := clampf(absf(speed) / 42.0, 0.0, 1.0)
    var engine_pitch := clampf(_rpm / 1800.0, 0.48, 3.40)
    var engine_db := -31.0 + speed_fraction * 6.0 + _load * 7.0
    _voice(engine, driving and desired_rpm > 0.0, engine_db, engine_pitch)

    var surface_pitch := 1.0
    var surface_gain := 0.0
    match _road_stream_key:
        "road_gravel":
            surface_pitch = 0.82
            surface_gain = 2.0
        "road_grass":
            surface_pitch = 0.70
            surface_gain = 2.5
        "road_skid":
            surface_pitch = 1.05
            surface_gain = 4.0
    var roll_pitch := (0.60 + absf(speed) * 0.042) * surface_pitch
    var roll_db := -43.0 + speed_fraction * 12.0 + surface_gain
    _voice(road_roll, driving and absf(speed) > 0.5, roll_db, roll_pitch)

    var step_pitch := clampf(pow(maxf(walk_speed, 0.1) / 3.8, 0.35), 0.75, 1.65)
    var step_db := -32.0 + clampf(walk_speed / 8.0, 0.0, 1.0) * 5.0
    if _footstep_one_shot_available:
        _one_shot_footsteps(not driving and walk_speed > 0.35, walk_speed, step_db, step_pitch, dt)
    else:
        _voice(footsteps, not driving and walk_speed > 0.35, step_db, step_pitch)
    # Low wind is deliberately subordinate to engine/footstep cues. It is a
    # general breeze, not an invented surf location or a geographic audio map.
    var ambient_speed := absf(speed) if driving else walk_speed
    _voice(wind, true, -49.0 + clampf(ambient_speed / 42.0, 0.0, 1.0) * 9.0, 0.70 + clampf(ambient_speed / 42.0, 0.0, 1.0) * 0.35)

func _one_shot_footsteps(enabled: bool, walk_speed: float, decibels: float, pitch: float, dt: float) -> void:
    if not enabled:
        footsteps.volume_db = SILENT_DB
        footsteps.stop()
        _step_clock = 0.0
        return
    footsteps.pitch_scale = clampf(pitch * (0.98 if (_step_index & 1) == 0 else 1.02), 0.45, 3.40)
    footsteps.volume_db = clampf(decibels + linear_to_db(maxf(volume, 0.0001)), SILENT_DB, -14.0)
    _step_clock -= dt
    if _step_clock > 0.0:
        return
    footsteps.stop()
    footsteps.play()
    _step_index += 1
    _step_clock = footstep_interval(walk_speed)

static func footstep_interval(walk_speed: float) -> float:
    if not is_finite(walk_speed):
        return 0.5
    # Walk ~2 Hz, fast run ~3.5 Hz. The source hit remains a one-shot rather
    # than being stretched into another continuous ambience loop.
    return clampf(0.60 - clampf(walk_speed, 0.0, 10.0) * 0.043, 0.28, 0.56)

func _resolve_surface(state: Dictionary, dt: float) -> String:
    if state.has("surface"):
        _surface_hint = _valid_surface(str(state.surface))
        return _surface_hint
    if bool(state.get("on_road", true)):
        _surface_hint = "paved"
        _surface_probe_clock = 0.0
        return _surface_hint
    # The legacy main state only tells audio paved-vs-not-paved. Probe the same
    # compiled road surface index at 5 Hz to separate gravel from true off-road
    # without adding a per-frame spatial query or modifying road truth.
    _surface_probe_clock += dt
    if _surface_probe_clock < 0.20:
        return _surface_hint
    _surface_probe_clock = 0.0
    _surface_hint = "offroad"
    var root_node: Node = get_parent()
    if root_node == null:
        return _surface_hint
    var roads := root_node.get_node_or_null("JamaicaRoadStreamer")
    var car := root_node.get_node_or_null("RoadQA") as Node3D
    if roads == null or car == null or not roads.has_method("local_to_world") or not roads.has_method("road_surface_at"):
        return _surface_hint
    var world_value: Variant = roads.call("local_to_world", car.position)
    if not world_value is PackedFloat64Array:
        return _surface_hint
    var world: PackedFloat64Array = world_value
    if world.size() < 3:
        return _surface_hint
    var surface_value: Variant = roads.call("road_surface_at", world[0], world[2])
    if not surface_value is Dictionary:
        return _surface_hint
    var surface_record: Dictionary = surface_value
    if bool(surface_record.get("found", false)):
        _surface_hint = _valid_surface(str(surface_record.get("surface", "offroad")))
    return _surface_hint

static func _valid_surface(value: String) -> String:
    return value if value in ["paved", "unpaved", "offroad"] else "offroad"

func debug_state() -> Dictionary:
    return {
        "voices": _voices.size(), "cache_build_count": _cache_build_count,
        "engine_playing": engine.playing if engine != null else false,
        "footsteps_playing": footsteps.playing if footsteps != null else false,
        "engine_pitch": engine.pitch_scale if engine != null else 1.0,
        "engine_db": engine.volume_db if engine != null else SILENT_DB,
        "road_pitch": road_roll.pitch_scale if road_roll != null else 1.0,
        "engine_stream_key": _engine_stream_key, "road_stream_key": _road_stream_key,
        "surface_hint": _surface_hint, "footstep_one_shot": _footstep_one_shot_available,
        "rpm": _rpm, "load": _load, "volume": volume,
    }

func _finite_value(value: Variant, low: float, high: float) -> float:
    var number := float(value) if value is float or value is int else 0.0
    return clampf(number, low, high) if is_finite(number) else 0.0

func _make_voice(voice_name: String, stream: AudioStreamWAV) -> AudioStreamPlayer:
    var player := AudioStreamPlayer.new()
    player.name = voice_name
    player.stream = stream
    player.volume_db = SILENT_DB
    player.max_polyphony = 1
    add_child(player)
    _voices.append(player)
    return player

func _route_stream(player: AudioStreamPlayer, key: String) -> void:
    var stream: AudioStream = _stream_cache.get(key) as AudioStream
    if stream == null or player.stream == stream:
        return
    var was_playing := player.playing
    player.stop()
    player.stream = stream
    if was_playing:
        player.play()

func _voice(player: AudioStreamPlayer, enabled: bool, decibels: float, pitch: float) -> void:
    if not enabled:
        player.volume_db = SILENT_DB
        player.stop()
        return
    player.pitch_scale = clampf(pitch, 0.45, 3.40)
    player.volume_db = clampf(decibels + linear_to_db(maxf(volume, 0.0001)), SILENT_DB, -14.0)
    if not player.playing:
        player.play()

func _silence() -> void:
    _step_clock = 0.0
    for player in _voices:
        player.volume_db = SILENT_DB
        player.stop()

static func engine_stream_key(speed_mps: float, load: float, rpm: float) -> String:
    if not is_finite(speed_mps) or not is_finite(load) or not is_finite(rpm):
        return "engine"
    return "engine_drive" if speed_mps > 3.0 or load > 0.24 or rpm > 1800.0 else "engine"

static func road_stream_key(surface: String, braking: float, speed_mps: float) -> String:
    if not is_finite(braking) or not is_finite(speed_mps):
        return "road"
    if surface == "paved" and braking >= 0.68 and speed_mps >= 5.0:
        return "road_skid"
    if surface == "unpaved":
        return "road_gravel"
    if surface == "offroad":
        return "road_grass"
    return "road"

static func optional_audio_contract() -> Dictionary:
    return {
        "files": OPTIONAL_AUDIO_FILES.duplicate(),
        "voice_budget": 4,
        "surface_routing": true,
        "footstep_one_shot": true,
        "fallback_safe": true,
        "compiled_surface_probe_hz": 5,
    }

static func _prepare_streams() -> void:
    if not _stream_cache.is_empty():
        return
    for kind in ["engine", "road", "footsteps", "wind"]:
        var seconds := 0.5 if kind == "engine" else 1.0
        var samples := int(round(seconds * SAMPLE_RATE)) + 1
        var pcm := PackedByteArray()
        pcm.resize(samples * 2)
        for index in range(samples):
            var t := seconds * float(index) / float(samples - 1)
            var value := _sample(kind, t)
            pcm.encode_s16(index * 2, int(round(clampf(value, -0.90, 0.90) * 32767.0)))
        # Equal endpoints avoid a discontinuity even after integer quantising.
        pcm.encode_s16((samples - 1) * 2, pcm.decode_s16(0))
        var stream := AudioStreamWAV.new()
        stream.format = AudioStreamWAV.FORMAT_16_BITS
        stream.mix_rate = SAMPLE_RATE
        stream.stereo = false
        stream.data = pcm
        stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
        stream.loop_begin = 0
        stream.loop_end = samples
        _stream_cache[kind] = stream
    for kind in ["engine", "footsteps", "road"]:
        var filename: String = "road_roll_loop.wav" if kind == "road" else kind + "_loop.wav"
        var reference := References.audio(filename, true) as AudioStreamWAV
        if reference != null:
            _stream_cache[kind] = reference
    var fallbacks := {
        "engine_drive": "engine",
        "road_gravel": "road",
        "road_grass": "road",
        "road_skid": "road",
    }
    for key: String in ["engine_drive", "road_gravel", "road_grass", "road_skid"]:
        var reference := References.audio(str(OPTIONAL_AUDIO_FILES[key]), true) as AudioStreamWAV
        _stream_cache[key] = reference if reference != null else _stream_cache[str(fallbacks[key])]
    var footstep_one_shot := References.audio(str(OPTIONAL_AUDIO_FILES.footstep_one_shot), false) as AudioStreamWAV
    _footstep_one_shot_available = footstep_one_shot != null
    _stream_cache.footstep_one_shot = footstep_one_shot if footstep_one_shot != null else _stream_cache.footsteps
    _cache_build_count += 1

static func _sample(kind: String, t: float) -> float:
    match kind:
        "engine":
            var pulse := sin(TAU * 60.0 * t) * 0.32 + sin(TAU * 120.0 * t) * 0.16 + sin(TAU * 180.0 * t) * 0.065 + sin(TAU * 300.0 * t) * 0.035
            return pulse * (0.88 + 0.12 * cos(TAU * 4.0 * t))
        "road":
            var noise := 0.0
            var frequencies := [97.0, 211.0, 353.0, 607.0, 911.0, 1301.0, 1733.0]
            for harmonic in range(frequencies.size()):
                noise += sin(TAU * frequencies[harmonic] * t + float(harmonic) * 1.913) / (float(harmonic) + 2.0)
            return noise * 0.22
        "footsteps":
            var strike := 0.0
            for start in [0.055, 0.555]:
                var elapsed: float = t - start
                if elapsed >= 0.0 and elapsed < 0.14:
                    var envelope := sin(PI * minf(elapsed / 0.008, 1.0) * 0.5) * exp(-elapsed * 34.0)
                    strike += envelope * (sin(TAU * 93.0 * elapsed) * 0.33 + sin(TAU * 317.0 * elapsed) * 0.10 + sin(TAU * 821.0 * elapsed) * 0.04)
            return strike
        "wind":
            return (sin(TAU * 29.0 * t) * 0.13 + sin(TAU * 47.0 * t + 0.4) * 0.095 + sin(TAU * 79.0 * t + 1.7) * 0.06 + sin(TAU * 131.0 * t + 2.4) * 0.04) * (0.8 + 0.2 * cos(TAU * 2.0 * t))
    return 0.0
