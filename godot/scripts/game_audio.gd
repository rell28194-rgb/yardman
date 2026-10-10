@static_unload
extends Node
class_name YardmanGameAudio

# Original PCM is synthesised once and reused across instances. There are no
# downloaded samples, licensed sound packs, or per-frame waveform allocations.
const SAMPLE_RATE := 22050
const SILENT_DB := -80.0
static var _stream_cache: Dictionary = {}
static var _cache_build_count := 0
static var _active_instances := 0

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

func _ready() -> void:
    if not _configured:
        configure()

func configure(profile: String = "Balanced", default_volume: float = 0.60) -> void:
    quality = profile
    if not _configured:
        _prepare_streams()
        engine = _make_voice("Engine", _stream_cache.engine)
        road_roll = _make_voice("RoadRoll", _stream_cache.road)
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
    var speed := _finite_value(state.get("speed_mps", 0.0), -100.0, 100.0)
    var walk_speed := absf(_finite_value(state.get("walk_speed", 0.0), 0.0, 15.0))
    var desired_rpm := _finite_value(state.get("rpm", 900.0), 0.0, 7000.0)
    var acceleration := (absf(speed) - absf(_previous_speed)) / dt if _last_driving and driving else 0.0
    var desired_load := clampf(0.12 + maxf(acceleration, 0.0) / 7.0, 0.0, 1.0)
    if state.has("throttle"):
        desired_load = absf(_finite_value(state.throttle, -1.0, 1.0))
    _rpm = lerpf(_rpm, desired_rpm, 1.0 - exp(-dt * 6.0))
    _load = lerpf(_load, desired_load, 1.0 - exp(-dt * 7.0))
    _previous_speed = speed
    _last_driving = driving
    if not active or volume <= 0.0001:
        _silence()
        return
    var road_surface := bool(state.get("on_road", true))
    var speed_fraction := clampf(absf(speed) / 42.0, 0.0, 1.0)
    var engine_pitch := clampf(_rpm / 1800.0, 0.48, 3.40)
    var engine_db := -31.0 + speed_fraction * 6.0 + _load * 7.0
    _voice(engine, driving and desired_rpm > 0.0, engine_db, engine_pitch)
    var roll_pitch := (0.60 + absf(speed) * 0.042) * (1.0 if road_surface else 0.70)
    var roll_db := -43.0 + speed_fraction * 12.0 + (0.0 if road_surface else 2.5)
    _voice(road_roll, driving and absf(speed) > 0.5, roll_db, roll_pitch)
    var step_pitch := clampf(pow(maxf(walk_speed, 0.1) / 3.8, 0.35), 0.75, 1.65)
    var step_db := -32.0 + clampf(walk_speed / 8.0, 0.0, 1.0) * 5.0
    _voice(footsteps, not driving and walk_speed > 0.35, step_db, step_pitch)
    # Low wind is deliberately subordinate to engine/footstep cues. It is a
    # general breeze, not an invented surf location or a geographic audio map.
    var ambient_speed := absf(speed) if driving else walk_speed
    _voice(wind, true, -49.0 + clampf(ambient_speed / 42.0, 0.0, 1.0) * 9.0, 0.70 + clampf(ambient_speed / 42.0, 0.0, 1.0) * 0.35)

func debug_state() -> Dictionary:
    return {
        "voices": _voices.size(), "cache_build_count": _cache_build_count,
        "engine_playing": engine.playing if engine != null else false,
        "footsteps_playing": footsteps.playing if footsteps != null else false,
        "engine_pitch": engine.pitch_scale if engine != null else 1.0,
        "engine_db": engine.volume_db if engine != null else SILENT_DB,
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
    player.volume_db = clampf(decibels + linear_to_db(maxf(volume, 0.0001)), SILENT_DB, -14.0)
    if not player.playing:
        player.play()

func _silence() -> void:
    for player in _voices:
        player.volume_db = SILENT_DB
        player.stop()

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
