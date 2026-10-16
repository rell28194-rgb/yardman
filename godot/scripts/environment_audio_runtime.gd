@static_unload
extends Node
class_name YardmanEnvironmentAudioRuntime

const SAMPLE_RATE := 22050
const SILENT_DB := -80.0
const MAX_AMBIENT_VOICES := 5
const LAYERS := ["ocean", "wind", "birds", "insects", "settlement"]
const NightPolicy = preload("res://scripts/vehicle_headlight_runtime.gd")

static var _streams: Dictionary = {}

var renderer := "mobile"
var quality := "Balanced"
var thermal_stage := 0
var master_volume := 0.42
var _voice_budget := 4
var _gain_scale := 1.0
var _context_interval := 0.85
var _players: Dictionary = {}
var _configured := false
var _context_clock := 999.0
var _mix_clock := 999.0
const MIX_INTERVAL := 0.10
var _coast_factor := 0.0
var _activity_factor := 0.0
var _last_mix: Dictionary = {}
var _last_selected: Array[String] = []

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    add_to_group("yardman_render_quality")
    configure()

func configure() -> void:
    if _configured:
        return
    _prepare_streams()
    for layer in LAYERS:
        var player := AudioStreamPlayer.new()
        player.name = "Ambience_" + layer.capitalize()
        player.stream = _streams[layer]
        player.volume_db = SILENT_DB
        player.max_polyphony = 1
        add_child(player)
        _players[layer] = player
    _configured = true

func _exit_tree() -> void:
    _silence()
    for player_value in _players.values():
        var player := player_value as AudioStreamPlayer
        if player != null:
            player.stream = null
    _players.clear()
    _configured = false

func _process(delta: float) -> void:
    if not _configured:
        configure()
    var scene := get_tree().current_scene
    if scene == null:
        _silence()
        return
    var player = scene.get("player")
    var car = scene.get("car")
    var roads = scene.get("roads")
    var terrain = scene.get("terrain")
    if player == null or car == null or roads == null or terrain == null:
        _silence()
        return
    var active: Node3D = car as Node3D if bool(player.get("in_vehicle")) else player as Node3D
    if active == null:
        _silence()
        return

    _context_clock += delta
    if _context_clock >= _context_interval:
        _context_clock = 0.0
        var world_value = roads.call("local_to_world", active.global_position)
        if world_value is PackedFloat64Array and world_value.size() >= 3:
            _coast_factor = coast_factor_for_terrain(terrain, float(world_value[0]), float(world_value[2]))
        _activity_factor = activity_factor_from_runtimes(
            get_node_or_null("/root/TrafficRuntime"), get_node_or_null("/root/PedestrianRuntime"))

    _mix_clock += delta
    if _mix_clock < MIX_INTERVAL:
        return
    _mix_clock = 0.0
    var atmosphere := get_node_or_null("/root/AtmosphereFX")
    var rain := 0.0
    if atmosphere != null:
        rain = clampf(float(atmosphere.get("rain_intensity")), 0.0, 1.0)
    var driving := bool(player.get("in_vehicle"))
    var speed := 0.0
    var vehicle = scene.get("vehicle")
    if driving and vehicle != null:
        speed = absf(float(vehicle.get("speed_mps")))
    var hour := float(scene.get("day_hour"))
    _last_mix = mix_for_context(hour, rain, _coast_factor, _activity_factor, speed, driving)
    _last_selected = select_layers(_last_mix, _voice_budget)
    _apply_mix(_last_mix, _last_selected)

func apply_render_policy(active: Dictionary) -> void:
    renderer = str(active.get("renderer", renderer))
    quality = str(active.get("quality", quality))
    thermal_stage = clampi(int(active.get("thermal_stage", thermal_stage)), 0, 5)
    var budget := budget_for(quality, thermal_stage, renderer)
    _voice_budget = int(budget.voices)
    _gain_scale = float(budget.gain_scale)
    _context_interval = float(budget.context_interval)

static func budget_for(quality_name: String, stage_value: int, renderer_name: String = "mobile") -> Dictionary:
    var voices := 4
    var gain := 1.0
    var interval := 0.85
    match quality_name:
        "Performance":
            voices = 3
            gain = 0.92
            interval = 1.25
        "Quality":
            voices = 5
            gain = 1.0
            interval = 0.72
        "Ultra":
            voices = 5
            gain = 1.03
            interval = 0.62
    if renderer_name == "gl_compatibility" or renderer_name == "gles":
        voices = mini(voices, 4)
        interval = maxf(interval, 0.90)
    var stage := clampi(stage_value, 0, 5)
    var voice_caps: Array[int] = [voices, voices, maxi(3, voices - 1), maxi(3, voices - 1), 3, 2]
    var gain_factors: Array[float] = [1.0, 1.0, 0.96, 0.91, 0.86, 0.80]
    return {
        "voices": clampi(voice_caps[stage], 2, MAX_AMBIENT_VOICES),
        "gain_scale": gain * gain_factors[stage],
        "context_interval": interval * (1.0 + float(stage) * 0.12),
        "thermal_stage": stage,
    }

static func mix_for_context(hour: float, rain: float, coast: float, activity: float,
        speed_mps: float = 0.0, driving: bool = false) -> Dictionary:
    var h := fmod(hour + 24.0, 24.0)
    var rain_level := clampf(rain, 0.0, 1.0)
    var coast_level := clampf(coast, 0.0, 1.0)
    var activity_level := clampf(activity, 0.0, 1.0)
    var daylight := clampf(sin((h - 6.0) * PI / 12.0), 0.0, 1.0)
    var night := NightPolicy.night_factor(h)
    var morning := smoothstep(5.75, 7.25, h) * (1.0 - smoothstep(10.0, 12.0, h)) if h < 12.0 else 0.0
    var evening := smoothstep(17.0, 19.0, h) * (1.0 - smoothstep(22.0, 23.5, h)) if h >= 17.0 else 0.0
    var weather_clear := 1.0 - rain_level
    var vehicle_mask := 0.56 if driving else 1.0
    var speed_wind := clampf(absf(speed_mps) / 62.0, 0.0, 1.0)
    return {
        "ocean": clampf(coast_level * (0.62 + rain_level * 0.30) * (0.82 + weather_clear * 0.18), 0.0, 1.0),
        "wind": clampf((0.10 + rain_level * 0.70 + speed_wind * 0.18) * vehicle_mask, 0.0, 1.0),
        "birds": clampf((0.18 * daylight + 0.82 * morning) * weather_clear * (1.0 - activity_level * 0.20), 0.0, 1.0),
        "insects": clampf((night * 0.76 + evening * 0.28) * (1.0 - rain_level * 0.68) * (1.0 - activity_level * 0.12), 0.0, 1.0),
        "settlement": clampf(activity_level * (0.52 + evening * 0.30 + night * 0.12) * (1.0 - rain_level * 0.18), 0.0, 1.0),
    }

static func select_layers(mix: Dictionary, voice_budget: int) -> Array[String]:
    var ranked: Array[Dictionary] = []
    for layer in LAYERS:
        ranked.append({"layer": layer, "weight": clampf(float(mix.get(layer, 0.0)), 0.0, 1.0)})
    ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        if is_equal_approx(float(a.weight), float(b.weight)):
            return str(a.layer) < str(b.layer)
        return float(a.weight) > float(b.weight))
    var selected: Array[String] = []
    var limit := clampi(voice_budget, 0, MAX_AMBIENT_VOICES)
    for entry in ranked:
        if selected.size() >= limit:
            break
        if float(entry.weight) <= 0.018:
            continue
        selected.append(str(entry.layer))
    return selected

static func activity_factor_from_counts(traffic_count: int, traffic_budget: int,
        pedestrian_count: int, pedestrian_budget: int) -> float:
    var traffic_fraction := clampf(float(maxi(traffic_count, 0)) / float(maxi(traffic_budget, 1)), 0.0, 1.0)
    var pedestrian_fraction := clampf(float(maxi(pedestrian_count, 0)) / float(maxi(pedestrian_budget, 1)), 0.0, 1.0)
    return clampf(traffic_fraction * 0.58 + pedestrian_fraction * 0.42, 0.0, 1.0)

static func activity_factor_from_runtimes(traffic, pedestrians) -> float:
    var traffic_count := 0
    var traffic_budget := 1
    var pedestrian_count := 0
    var pedestrian_budget := 1
    if traffic != null:
        var traffic_agents = traffic.get("agents")
        if traffic_agents is Dictionary:
            traffic_count = traffic_agents.size()
        traffic_budget = maxi(int(traffic.get("max_agents")), 1)
    if pedestrians != null:
        var pedestrian_agents = pedestrians.get("agents")
        if pedestrian_agents is Dictionary:
            pedestrian_count = pedestrian_agents.size()
        pedestrian_budget = maxi(int(pedestrians.get("max_agents")), 1)
    return activity_factor_from_counts(traffic_count, traffic_budget, pedestrian_count, pedestrian_budget)

static func coast_factor_from_payload(payload: Dictionary, tile: Vector2i, world_x: float, world_z: float,
        tile_size: float, spacing: float, resolution: int, radius_m: float = 620.0) -> float:
    var mask: PackedByteArray = payload.get("mask", PackedByteArray())
    var cells := resolution - 1
    if cells <= 0 or mask.size() != cells * cells or spacing <= 0.0:
        return 0.0
    var local_x := world_x - float(tile.x) * tile_size
    var local_z := world_z - float(tile.y) * tile_size
    var center_x := floori(local_x / spacing)
    var center_z := floori(local_z / spacing)
    var radius_cells := ceili(radius_m / spacing) + 1
    var best := INF
    var min_x := maxi(0, center_x - radius_cells)
    var max_x := mini(cells - 1, center_x + radius_cells)
    var min_z := maxi(0, center_z - radius_cells)
    var max_z := mini(cells - 1, center_z + radius_cells)
    if min_x > max_x or min_z > max_z:
        return 0.0
    for z in range(min_z, max_z + 1):
        for x in range(min_x, max_x + 1):
            var classification := int(mask[z * cells + x])
            var shoreline := classification == 2
            if not shoreline:
                if x > 0 and int(mask[z * cells + x - 1]) != classification:
                    shoreline = true
                elif x + 1 < cells and int(mask[z * cells + x + 1]) != classification:
                    shoreline = true
                elif z > 0 and int(mask[(z - 1) * cells + x]) != classification:
                    shoreline = true
                elif z + 1 < cells and int(mask[(z + 1) * cells + x]) != classification:
                    shoreline = true
            if not shoreline:
                continue
            var shore_x := float(tile.x) * tile_size + (float(x) + 0.5) * spacing
            var shore_z := float(tile.y) * tile_size + (float(z) + 0.5) * spacing
            best = minf(best, Vector2(world_x - shore_x, world_z - shore_z).length())
    if not is_finite(best):
        return 0.0
    return 1.0 - smoothstep(75.0, radius_m, best)

static func coast_factor_for_terrain(terrain, world_x: float, world_z: float) -> float:
    if terrain == null:
        return 0.0
    var coast_data_value = terrain.get("_coast_data")
    if not coast_data_value is Dictionary:
        return 0.0
    var coast_data: Dictionary = coast_data_value
    var tile_size := float(terrain.get("tile_size"))
    var spacing := float(terrain.get("spacing"))
    var resolution := int(terrain.get("resolution"))
    var best_factor := 0.0
    for key_value in coast_data.keys():
        var pieces := str(key_value).split(":")
        if pieces.size() != 2:
            continue
        var tile := Vector2i(int(pieces[0]), int(pieces[1]))
        var payload_value = coast_data[key_value]
        if not payload_value is Dictionary:
            continue
        best_factor = maxf(best_factor, coast_factor_from_payload(payload_value, tile, world_x, world_z,
            tile_size, spacing, resolution))
        if best_factor >= 0.995:
            break
    return best_factor

func _apply_mix(mix: Dictionary, selected: Array[String]) -> void:
    for layer in LAYERS:
        var player := _players.get(layer) as AudioStreamPlayer
        if player == null:
            continue
        var weight := clampf(float(mix.get(layer, 0.0)), 0.0, 1.0) if layer in selected else 0.0
        var base_db := -21.0
        match layer:
            "ocean": base_db = -19.5
            "wind": base_db = -23.0
            "birds": base_db = -22.0
            "insects": base_db = -23.0
            "settlement": base_db = -24.0
        _voice(player, weight, base_db)

func _voice(player: AudioStreamPlayer, weight: float, base_db: float) -> void:
    if weight <= 0.018 or master_volume <= 0.0001:
        player.volume_db = SILENT_DB
        player.stop()
        return
    var gain := clampf(weight * master_volume * _gain_scale, 0.0001, 1.0)
    player.volume_db = clampf(base_db + linear_to_db(gain), SILENT_DB, -14.0)
    if not player.playing:
        player.play()

func _silence() -> void:
    for player_value in _players.values():
        var player := player_value as AudioStreamPlayer
        if player != null:
            player.volume_db = SILENT_DB
            player.stop()

static func _prepare_streams() -> void:
    if not _streams.is_empty():
        return
    for layer in LAYERS:
        _streams[layer] = _make_loop(layer, 2.0)

static func _make_loop(kind: String, seconds: float) -> AudioStreamWAV:
    var samples: int = int(round(seconds * SAMPLE_RATE)) + 1
    var pcm := PackedByteArray()
    pcm.resize(samples * 2)
    var seed: int = int(abs(kind.hash())) % 100003 + 17
    for index: int in range(samples):
        var normalized: float = float(index) / float(maxi(samples - 1, 1))
        var phase: float = TAU * normalized
        var noise_seed: int = int(posmod(index * 1103515245 + seed * 12345, 2147483647))
        var noise: float = float(noise_seed % 65536) / 32767.5 - 1.0
        var sample: float = 0.0
        match kind:
            "ocean":
                var swell: float = sin(phase) * 0.52 + sin(phase * 3.0 + 0.4) * 0.23
                var wash: float = noise * (0.10 + 0.08 * (sin(phase * 2.0) * 0.5 + 0.5))
                sample = swell * 0.34 + wash
            "wind":
                sample = noise * 0.14 + sin(phase * 2.0) * 0.055 + sin(phase * 5.0 + 0.8) * 0.025
            "birds":
                var bird_gate: float = pow(maxf(sin(phase * 2.0), 0.0), 7.0) + 0.72 * pow(maxf(sin(phase * 3.0 + 1.6), 0.0), 9.0)
                sample = sin(phase * 63.0 + sin(phase * 2.0) * 7.0) * bird_gate * 0.16
            "insects":
                var insect_gate: float = 0.58 + 0.42 * sin(phase * 4.0) * sin(phase * 4.0)
                sample = (sin(phase * 94.0) * 0.09 + sin(phase * 121.0 + 0.3) * 0.055) * insect_gate
            "settlement":
                sample = sin(phase * 5.0) * 0.045 + sin(phase * 11.0 + 0.6) * 0.025 + noise * 0.065
        var encoded: int = int(round(clampf(sample, -0.92, 0.92) * 32767.0))
        pcm.encode_s16(index * 2, encoded)
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

func runtime_snapshot() -> Dictionary:
    return {
        "voice_budget": _voice_budget,
        "selected_layers": _last_selected.duplicate(),
        "coast_factor": _coast_factor,
        "activity_factor": _activity_factor,
        "mix": _last_mix.duplicate(true),
        "renderer": renderer,
        "quality": quality,
        "thermal_stage": thermal_stage,
    }
