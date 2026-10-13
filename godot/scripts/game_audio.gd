@static_unload
extends Node
class_name YardmanGameAudio

const References = preload("res://scripts/reference_assets.gd")
const SAMPLE_RATE := 22050
const SILENT_DB := -80.0
static var _stream_cache: Dictionary = {}
static var _cache_build_count := 0
static var _active_instances := 0

var engine: AudioStreamPlayer
var engine_drive: AudioStreamPlayer
var road_roll: AudioStreamPlayer
var offroad_roll: AudioStreamPlayer
var footsteps: AudioStreamPlayer
var wind: AudioStreamPlayer
var quality := "Balanced"
var volume := 0.72
var _voices: Array[AudioStreamPlayer] = []
var _configured := false
var _rpm := 900.0
var _load := 0.0
var _previous_speed := 0.0
var _last_driving := false

func _ready() -> void:
    if not _configured:
        configure()

func configure(profile: String = "Balanced", default_volume: float = 0.72) -> void:
    quality = profile
    if not _configured:
        _prepare_streams()
        engine = _make_voice("EngineIdle", _stream_cache.engine_idle)
        engine_drive = _make_voice("EngineDrive", _stream_cache.engine_drive)
        road_roll = _make_voice("RoadRoll", _stream_cache.road)
        offroad_roll = _make_voice("OffroadRoll", _stream_cache.offroad)
        footsteps = _make_voice("Footsteps", _stream_cache.footsteps)
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
    var speed := _finite_value(state.get("speed_mps", 0.0), -120.0, 120.0)
    var walk_speed := absf(_finite_value(state.get("walk_speed", 0.0), 0.0, 15.0))
    var desired_rpm := _finite_value(state.get("rpm", 900.0), 0.0, 7200.0)
    var acceleration := (absf(speed) - absf(_previous_speed)) / dt if _last_driving and driving else 0.0
    var desired_load := clampf(0.10 + maxf(acceleration, 0.0) / 7.5, 0.0, 1.0)
    if state.has("throttle"):
        desired_load = absf(_finite_value(state.throttle, -1.0, 1.0))
    _rpm = lerpf(_rpm, desired_rpm, 1.0 - exp(-dt * 7.5))
    _load = lerpf(_load, desired_load, 1.0 - exp(-dt * 8.0))
    _previous_speed = speed
    _last_driving = driving
    if not active or volume <= 0.0001:
        _silence()
        return

    var road_surface := bool(state.get("on_road", true))
    var speed_fraction := clampf(absf(speed) / 58.0, 0.0, 1.0)
    var rpm_fraction := clampf((_rpm - 800.0) / 6100.0, 0.0, 1.0)
    var drive_mix := clampf(rpm_fraction * 1.15 + _load * 0.35, 0.0, 1.0)
    var idle_mix := 1.0 - smoothstep(0.16, 0.64, drive_mix)
    var loaded_mix := smoothstep(0.05, 0.46, drive_mix)

    var idle_pitch := clampf(0.82 + rpm_fraction * 0.72, 0.78, 1.55)
    var drive_pitch := clampf(0.70 + rpm_fraction * 1.72, 0.68, 2.42)
    var idle_db := -24.5 + idle_mix * 5.0 + _load * 1.5
    var drive_db := -34.0 + loaded_mix * 13.0 + _load * 5.5
    _voice(engine, driving and desired_rpm > 0.0 and idle_mix > 0.015, idle_db + linear_to_db(maxf(idle_mix, 0.015)), idle_pitch)
    _voice(engine_drive, driving and desired_rpm > 0.0 and loaded_mix > 0.015, drive_db + linear_to_db(maxf(loaded_mix, 0.015)), drive_pitch)

    var roll_pitch := clampf(0.66 + absf(speed) * 0.030, 0.62, 2.12)
    var roll_db := -41.0 + speed_fraction * 15.0
    _voice(road_roll, driving and road_surface and absf(speed) > 0.8, roll_db, roll_pitch)
    _voice(offroad_roll, driving and not road_surface and absf(speed) > 0.55,
        -38.0 + speed_fraction * 14.0, clampf(0.66 + absf(speed) * 0.022, 0.62, 1.75))

    var step_pitch := clampf(pow(maxf(walk_speed, 0.1) / 3.8, 0.35), 0.75, 1.65)
    var step_db := -32.0 + clampf(walk_speed / 8.0, 0.0, 1.0) * 5.0
    _voice(footsteps, not driving and walk_speed > 0.35, step_db, step_pitch)
    var ambient_speed := absf(speed) if driving else walk_speed
    _voice(wind, true, -50.0 + clampf(ambient_speed / 58.0, 0.0, 1.0) * 11.0,
        0.70 + clampf(ambient_speed / 58.0, 0.0, 1.0) * 0.38)

func debug_state() -> Dictionary:
    return {
        "voices": _voices.size(), "cache_build_count": _cache_build_count,
        "engine_playing": engine.playing if engine != null else false,
        "engine_drive_playing": engine_drive.playing if engine_drive != null else false,
        "footsteps_playing": footsteps.playing if footsteps != null else false,
        "engine_pitch": engine.pitch_scale if engine != null else 1.0,
        "engine_drive_pitch": engine_drive.pitch_scale if engine_drive != null else 1.0,
        "engine_db": engine.volume_db if engine != null else SILENT_DB,
        "engine_drive_db": engine_drive.volume_db if engine_drive != null else SILENT_DB,
        "road_pitch": road_roll.pitch_scale if road_roll != null else 1.0,
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

func _voice(player: AudioStreamPlayer, enabled: bool, decibels: float, pitch: float) -> void:
    if not enabled:
        player.volume_db = SILENT_DB
        player.stop()
        return
    player.pitch_scale = clampf(pitch, 0.45, 3.40)
    player.volume_db = clampf(decibels + linear_to_db(maxf(volume, 0.0001)), SILENT_DB, -10.0)
    if not player.playing:
        player.play()

func _silence() -> void:
    for player in _voices:
        player.volume_db = SILENT_DB
        player.stop()

static func _prepare_streams() -> void:
    if not _stream_cache.is_empty():
        return
    for kind in ["engine_idle", "engine_drive", "road", "offroad", "footsteps", "wind"]:
        var seconds := 0.75 if kind.begins_with("engine") else 1.0
        var samples := int(round(seconds * SAMPLE_RATE)) + 1
        var pcm := PackedByteArray()
        pcm.resize(samples * 2)
        for index in range(samples):
            var t := seconds * float(index) / float(samples - 1)
            var value := _sample(kind, t)
            pcm.encode_s16(index * 2, int(round(clampf(value, -0.90, 0.90) * 32767.0)))
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

    var mappings := {
        "engine_idle": "engine_loop.wav",
        "engine_drive": "engine_drive_loop.wav",
        "road": "road_roll_loop.wav",
        "offroad": "grass_roll_loop.wav",
        "footsteps": "footsteps_loop.wav",
    }
    for kind in mappings:
        var reference := References.audio(str(mappings[kind]), true) as AudioStreamWAV
        if reference != null:
            _stream_cache[kind] = reference
    _cache_build_count += 1

static func _sample(kind: String, t: float) -> float:
    match kind:
        "engine_idle":
            var pulse := sin(TAU * 48.0 * t) * 0.30 + sin(TAU * 96.0 * t) * 0.15 + sin(TAU * 144.0 * t) * 0.075 + sin(TAU * 240.0 * t) * 0.035
            return pulse * (0.86 + 0.14 * cos(TAU * 3.0 * t))
        "engine_drive":
            var engine_note := sin(TAU * 71.0 * t) * 0.27 + sin(TAU * 142.0 * t) * 0.18 + sin(TAU * 213.0 * t) * 0.095 + sin(TAU * 355.0 * t) * 0.052
            return engine_note * (0.88 + 0.12 * sin(TAU * 5.0 * t))
        "road":
            var noise := 0.0
            var frequencies := [97.0, 211.0, 353.0, 607.0, 911.0, 1301.0, 1733.0]
            for harmonic in range(frequencies.size()):
                noise += sin(TAU * frequencies[harmonic] * t + float(harmonic) * 1.913) / (float(harmonic) + 2.0)
            return noise * 0.22
        "offroad":
            return (sin(TAU * 51.0 * t) * 0.17 + sin(TAU * 117.0 * t + 0.7) * 0.10 + sin(TAU * 337.0 * t + 2.0) * 0.055) * (0.78 + 0.22 * sin(TAU * 7.0 * t))
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