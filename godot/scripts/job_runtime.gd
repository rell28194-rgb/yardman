extends Node
class_name YardmanJobRuntime

const UPDATE_INTERVAL := 0.20
const ARRIVAL_RADIUS_M := 90.0
const MAX_VALID_STEP_M := 220.0
const STARTING_WALLET_JMD := 5000
const OFFER_COUNT := 3
const CONTRACT_STANDARD := "standard"
const CONTRACT_EXPRESS := "express"
const EXPRESS_REWARD_MULTIPLIER := 1.35

var wallet_jmd := STARTING_WALLET_JMD
# Null keeps legacy garage saves authoritative until the first paid purchase.
# Once present, ownership and wallet travel in the same atomic save record.
var garage_owned_ids: Variant = null
var active_job: Dictionary = {}
var _offers: Array[Dictionary] = []
var _offer_sequence := 0
var _clock := 0.0
var _last_world := Vector2(INF, INF)
var _layer: CanvasLayer
var _jobs_button: Button
var _mission_label: Label
var _panel: PanelContainer
var _wallet_label: Label
var _offer_box: VBoxContainer
var _active_label: Label
var _abandon_button: Button

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    _build_ui()

func _process(delta: float) -> void:
    _clock += delta
    if _clock < UPDATE_INTERVAL:
        return
    var step := _clock
    _clock = 0.0
    var scene := get_tree().current_scene
    if scene == null:
        _set_world_ui_visible(false)
        _last_world = Vector2(INF, INF)
        return
    var roads = scene.get("roads")
    var player = scene.get("player")
    var car = scene.get("car")
    var vehicle = scene.get("vehicle")
    if roads == null or player == null or car == null or vehicle == null:
        _set_world_ui_visible(false)
        return
    _set_world_ui_visible(true)
    if _offers.is_empty() and active_job.is_empty():
        _refresh_offers(scene, roads)

    var active: Node3D = car if bool(player.get("in_vehicle")) else player
    var world_value = roads.call("local_to_world", active.position)
    if not world_value is PackedFloat64Array or world_value.size() < 3:
        return
    var world := Vector2(float(world_value[0]), float(world_value[2]))
    if not active_job.is_empty():
        if str(active_job.get("contract_type", CONTRACT_STANDARD)) == CONTRACT_EXPRESS and not get_tree().paused:
            active_job["time_remaining_s"] = maxf(0.0, float(active_job.get("time_remaining_s", 0.0)) - step)
            if float(active_job.get("time_remaining_s", 0.0)) <= 0.0:
                _expire_job(scene, roads)
                _last_world = world
                _update_ui()
                return
        var in_vehicle := bool(player.get("in_vehicle"))
        if in_vehicle and is_finite(_last_world.x):
            active_job["travelled_m"] = float(active_job.get("travelled_m", 0.0)) + eligible_travel_step(_last_world, world)
        var destination := Vector2(float(active_job.get("destination_x", world.x)), float(active_job.get("destination_z", world.y)))
        var distance_to_destination := world.distance_to(destination)
        active_job["remaining_m"] = distance_to_destination
        var speed_mps := absf(float(vehicle.get("speed_mps")))
        if completion_ready(distance_to_destination, speed_mps, in_vehicle,
                float(active_job.get("travelled_m", 0.0)), float(active_job.get("required_travel_m", 0.0))):
            _complete_job(scene, roads)
    _last_world = world
    _update_ui()

static func anchor_xz(anchor: Dictionary) -> Vector2:
    var road_position = anchor.get("road_position", [])
    if road_position is Array and road_position.size() >= 3:
        return Vector2(float(road_position[0]), float(road_position[2]))
    return Vector2(float(anchor.get("x", 0.0)), float(anchor.get("z", 0.0)))

static func reward_for_distance(distance_m: float) -> int:
    return maxi(900, int(round(1200.0 + maxf(distance_m, 0.0) * 0.19)))

static func reward_for_contract(distance_m: float, contract_type: String) -> int:
    var base := reward_for_distance(distance_m)
    return int(round(float(base) * EXPRESS_REWARD_MULTIPLIER)) if contract_type == CONTRACT_EXPRESS else base

static func required_travel_for_distance(distance_m: float) -> float:
    return clampf(maxf(distance_m, 0.0) * 0.55, 650.0, 60000.0)

static func express_deadline_for_distance(distance_m: float) -> float:
    # A gameplay deadline derived from real metre distance, with substantial
    # slack for Jamaica's road geometry, traffic, weather and stops. It is not
    # presented as a real-world travel-time estimate.
    return maxf(300.0, 120.0 + maxf(distance_m, 0.0) / 14.0 * 1.45)

static func express_slot_for(origin: String, sequence: int, count: int) -> int:
    return deterministic_seed(origin, sequence) % maxi(1, count)

static func eligible_travel_step(previous: Vector2, current: Vector2) -> float:
    if not is_finite(previous.x) or not is_finite(previous.y) or not is_finite(current.x) or not is_finite(current.y):
        return 0.0
    var distance := previous.distance_to(current)
    return distance if distance <= MAX_VALID_STEP_M else 0.0

static func completion_ready(distance_to_destination: float, speed_mps: float, in_vehicle: bool, travelled_m: float, required_travel_m: float) -> bool:
    return in_vehicle and distance_to_destination <= ARRIVAL_RADIUS_M and absf(speed_mps) <= 1.5 and travelled_m >= required_travel_m

static func deterministic_seed(origin: String, sequence: int) -> int:
    var value := int((origin + "|" + str(sequence) + "|yardman-jobs-v1").hash())
    if value == -9223372036854775808:
        return 0
    return absi(value)

static func offer_destinations(parishes: Array, origin: String, sequence: int, count: int = OFFER_COUNT) -> Array[String]:
    var candidates: Array[String] = []
    for value in parishes:
        var name := str(value)
        if not name.is_empty() and name != origin:
            candidates.append(name)
    candidates.sort()
    var result: Array[String] = []
    if candidates.is_empty():
        return result
    var start := deterministic_seed(origin, sequence) % candidates.size()
    var stride := 5 if candidates.size() > 5 else 1
    var cursor := start
    while result.size() < mini(count, candidates.size()):
        var candidate := candidates[cursor]
        if not result.has(candidate):
            result.append(candidate)
        cursor = (cursor + stride) % candidates.size()
        if cursor == start and result.size() < mini(count, candidates.size()):
            stride = 1
            cursor = (cursor + 1) % candidates.size()
    return result

static func format_time(seconds: float) -> String:
    var total := maxi(0, int(ceil(seconds)))
    var hours := total / 3600
    var minutes := (total % 3600) / 60
    var secs := total % 60
    return "%d:%02d:%02d" % [hours, minutes, secs] if hours > 0 else "%02d:%02d" % [minutes, secs]

func _refresh_offers(scene: Node, roads) -> void:
    _offers.clear()
    var anchors_value = roads.get("manifest")
    if not anchors_value is Dictionary:
        return
    var anchors = (anchors_value as Dictionary).get("parish_anchors", {})
    if not anchors is Dictionary:
        return
    var origin := str(scene.get("current_parish"))
    var origin_anchor = anchors.get(origin, {})
    if not origin_anchor is Dictionary or origin_anchor.is_empty():
        return
    var origin_xz := anchor_xz(origin_anchor)
    var parish_names: Array = anchors.keys()
    var destinations := offer_destinations(parish_names, origin, _offer_sequence)
    var express_slot := express_slot_for(origin, _offer_sequence, destinations.size())
    for index in range(destinations.size()):
        var destination := destinations[index]
        var destination_anchor = anchors.get(destination, {})
        if not destination_anchor is Dictionary or destination_anchor.is_empty():
            continue
        var destination_xz := anchor_xz(destination_anchor)
        var distance := origin_xz.distance_to(destination_xz)
        var contract_type := CONTRACT_EXPRESS if index == express_slot else CONTRACT_STANDARD
        var deadline := express_deadline_for_distance(distance) if contract_type == CONTRACT_EXPRESS else 0.0
        _offers.append({
            "id": "%s-%s-%d-%s" % [origin.replace(" ", "_"), destination.replace(" ", "_"), _offer_sequence, contract_type],
            "contract_type": contract_type,
            "origin_parish": origin,
            "destination_parish": destination,
            "origin_x": origin_xz.x,
            "origin_z": origin_xz.y,
            "destination_x": destination_xz.x,
            "destination_z": destination_xz.y,
            "distance_m": distance,
            "reward_jmd": reward_for_contract(distance, contract_type),
            "required_travel_m": required_travel_for_distance(distance),
            "deadline_s": deadline,
            "time_remaining_s": deadline,
            "travelled_m": 0.0,
            "remaining_m": distance,
        })
    _rebuild_offer_buttons()

func _accept_offer(offer: Dictionary) -> void:
    if not active_job.is_empty():
        return
    active_job = offer.duplicate(true)
    active_job["travelled_m"] = 0.0
    if str(active_job.get("contract_type", CONTRACT_STANDARD)) == CONTRACT_EXPRESS:
        active_job["time_remaining_s"] = float(active_job.get("deadline_s", 0.0))
    _offer_sequence += 1
    _offers.clear()
    _last_world = Vector2(INF, INF)
    _panel.visible = false
    _rebuild_offer_buttons()
    _update_ui()

func _complete_job(scene: Node, roads) -> void:
    var reward := int(active_job.get("reward_jmd", 0))
    var destination := str(active_job.get("destination_parish", "Jamaica"))
    var contract_type := str(active_job.get("contract_type", CONTRACT_STANDARD))
    wallet_jmd += reward
    active_job.clear()
    _last_world = Vector2(INF, INF)
    if scene.has_method("_notify"):
        scene.call("_notify", "%s complete • J$%d • %s" % ["Express delivery" if contract_type == CONTRACT_EXPRESS else "Delivery", reward, destination])
    _refresh_offers(scene, roads)

func _expire_job(scene: Node, roads) -> void:
    var destination := str(active_job.get("destination_parish", "Jamaica"))
    active_job.clear()
    _last_world = Vector2(INF, INF)
    if scene.has_method("_notify"):
        scene.call("_notify", "Express delivery expired • %s" % destination)
    _refresh_offers(scene, roads)

func _abandon_job() -> void:
    if active_job.is_empty():
        return
    active_job.clear()
    _last_world = Vector2(INF, INF)
    var scene := get_tree().current_scene
    if scene != null:
        var roads = scene.get("roads")
        if roads != null:
            _refresh_offers(scene, roads)
    _update_ui()

func save_snapshot() -> Dictionary:
    var state := {
        "wallet_jmd": wallet_jmd,
        "offer_sequence": _offer_sequence,
        "active_job": active_job.duplicate(true),
    }
    if garage_owned_ids is Array:
        state["garage_owned_ids"] = garage_owned_ids.duplicate()
    return state

func restore_snapshot(value: Variant) -> void:
    wallet_jmd = STARTING_WALLET_JMD
    garage_owned_ids = null
    _offer_sequence = 0
    active_job.clear()
    _offers.clear()
    _last_world = Vector2(INF, INF)
    if value is Dictionary:
        var state: Dictionary = value
        wallet_jmd = maxi(0, int(state.get("wallet_jmd", STARTING_WALLET_JMD)))
        var ownership = state.get("garage_owned_ids", null)
        if ownership is Array:
            garage_owned_ids = ownership.duplicate()
        _offer_sequence = maxi(0, int(state.get("offer_sequence", 0)))
        var job = state.get("active_job", {})
        if job is Dictionary and _valid_persisted_job(job):
            active_job = (job as Dictionary).duplicate(true)
    _rebuild_offer_buttons()
    _update_ui()

static func _valid_persisted_job(job: Dictionary) -> bool:
    for field in ["origin_parish", "destination_parish"]:
        if str(job.get(field, "")).is_empty():
            return false
    for field in ["destination_x", "destination_z", "reward_jmd", "required_travel_m", "travelled_m"]:
        var value = job.get(field, null)
        if not (value is int or value is float) or not is_finite(float(value)):
            return false
    if int(job.get("reward_jmd", 0)) < 0 or float(job.get("required_travel_m", 0.0)) < 0.0 or float(job.get("travelled_m", 0.0)) < 0.0:
        return false
    var contract_type := str(job.get("contract_type", CONTRACT_STANDARD))
    if contract_type not in [CONTRACT_STANDARD, CONTRACT_EXPRESS]:
        return false
    if contract_type == CONTRACT_EXPRESS:
        for field in ["deadline_s", "time_remaining_s"]:
            var timer_value = job.get(field, null)
            if not (timer_value is int or timer_value is float) or not is_finite(float(timer_value)) or float(timer_value) < 0.0:
                return false
    return true

func _build_ui() -> void:
    _layer = CanvasLayer.new()
    _layer.name = "YardmanJobsUI"
    _layer.layer = 22
    add_child(_layer)

    _jobs_button = Button.new()
    _jobs_button.name = "JobsButton"
    _jobs_button.text = "JOBS"
    _jobs_button.custom_minimum_size = Vector2(94.0, 48.0)
    _jobs_button.focus_mode = Control.FOCUS_NONE
    _jobs_button.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
    _jobs_button.position = Vector2(-108.0, -24.0)
    _jobs_button.pressed.connect(func() -> void:
        _panel.visible = not _panel.visible
        if _panel.visible:
            var scene := get_tree().current_scene
            if scene != null and active_job.is_empty():
                var roads = scene.get("roads")
                if roads != null:
                    _refresh_offers(scene, roads)
        _update_ui())
    _layer.add_child(_jobs_button)

    _mission_label = Label.new()
    _mission_label.name = "MissionStatus"
    _mission_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _mission_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
    _mission_label.position = Vector2(-210.0, 58.0)
    _mission_label.size = Vector2(420.0, 32.0)
    _layer.add_child(_mission_label)

    _panel = PanelContainer.new()
    _panel.name = "JobsPanel"
    _panel.custom_minimum_size = Vector2(500.0, 380.0)
    _panel.set_anchors_preset(Control.PRESET_CENTER)
    _panel.position = Vector2(-250.0, -190.0)
    _panel.visible = false
    _layer.add_child(_panel)

    var margin := MarginContainer.new()
    margin.add_theme_constant_override("margin_left", 18)
    margin.add_theme_constant_override("margin_right", 18)
    margin.add_theme_constant_override("margin_top", 16)
    margin.add_theme_constant_override("margin_bottom", 16)
    _panel.add_child(margin)
    var rows := VBoxContainer.new()
    rows.add_theme_constant_override("separation", 10)
    margin.add_child(rows)

    var title := Label.new()
    title.text = "YARDMAN • COURIER BOARD"
    title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    rows.add_child(title)
    _wallet_label = Label.new()
    _wallet_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    rows.add_child(_wallet_label)
    _active_label = Label.new()
    _active_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    rows.add_child(_active_label)
    _offer_box = VBoxContainer.new()
    _offer_box.add_theme_constant_override("separation", 8)
    rows.add_child(_offer_box)
    _abandon_button = Button.new()
    _abandon_button.text = "Abandon current delivery"
    _abandon_button.focus_mode = Control.FOCUS_NONE
    _abandon_button.pressed.connect(_abandon_job)
    rows.add_child(_abandon_button)
    var close_button := Button.new()
    close_button.text = "Close"
    close_button.focus_mode = Control.FOCUS_NONE
    close_button.pressed.connect(func() -> void: _panel.visible = false)
    rows.add_child(close_button)
    _update_ui()

func _rebuild_offer_buttons() -> void:
    if _offer_box == null:
        return
    for child in _offer_box.get_children():
        child.queue_free()
    if not active_job.is_empty():
        return
    if _offers.is_empty():
        var loading := Label.new()
        loading.text = "No courier offers available at this location yet."
        _offer_box.add_child(loading)
        return
    for offer in _offers:
        var button := Button.new()
        button.focus_mode = Control.FOCUS_NONE
        button.custom_minimum_size = Vector2(450.0, 56.0)
        var contract_type := str(offer.get("contract_type", CONTRACT_STANDARD))
        var prefix := "EXPRESS • " if contract_type == CONTRACT_EXPRESS else ""
        var timer := " • %s" % format_time(float(offer.get("deadline_s", 0.0))) if contract_type == CONTRACT_EXPRESS else ""
        button.text = "%s%s → %s  •  %.1f km  •  J$%d%s" % [prefix, str(offer.origin_parish), str(offer.destination_parish), float(offer.distance_m) / 1000.0, int(offer.reward_jmd), timer]
        button.pressed.connect(_accept_offer.bind(offer.duplicate(true)))
        _offer_box.add_child(button)

func _update_ui() -> void:
    if _jobs_button == null:
        return
    _jobs_button.text = "JOBS\nJ$%d" % wallet_jmd
    _wallet_label.text = "Wallet: J$%d" % wallet_jmd
    if active_job.is_empty():
        _mission_label.visible = false
        _active_label.text = "Choose a delivery. One board slot is an express contract with higher pay and a deadline."
        _abandon_button.visible = false
    else:
        var destination := str(active_job.get("destination_parish", ""))
        var remaining := maxf(0.0, float(active_job.get("remaining_m", active_job.get("distance_m", 0.0))))
        var travelled := float(active_job.get("travelled_m", 0.0))
        var required := float(active_job.get("required_travel_m", 0.0))
        var contract_type := str(active_job.get("contract_type", CONTRACT_STANDARD))
        var express := contract_type == CONTRACT_EXPRESS
        var timer_text := " • %s" % format_time(float(active_job.get("time_remaining_s", 0.0))) if express else ""
        _mission_label.visible = true
        _mission_label.text = "%s → %s  •  %.1f km%s" % ["EXPRESS" if express else "DELIVERY", destination, remaining / 1000.0, timer_text]
        _active_label.text = "Active: %s → %s\nType: %s\nReward: J$%d%s\nDriven: %.1f / %.1f km required\nStop within %.0f m of the destination to complete." % [
            str(active_job.get("origin_parish", "")), destination, "Express" if express else "Standard", int(active_job.get("reward_jmd", 0)),
            "\nTime left: %s" % format_time(float(active_job.get("time_remaining_s", 0.0))) if express else "",
            travelled / 1000.0, required / 1000.0, ARRIVAL_RADIUS_M]
        _abandon_button.visible = true

func _set_world_ui_visible(value: bool) -> void:
    if _jobs_button != null:
        _jobs_button.visible = value
    if _mission_label != null and not value:
        _mission_label.visible = false
    if _panel != null and not value:
        _panel.visible = false

func runtime_snapshot() -> Dictionary:
    return {
        "wallet_jmd": wallet_jmd,
        "active": not active_job.is_empty(),
        "offers": _offers.size(),
        "offer_sequence": _offer_sequence,
        "travelled_m": float(active_job.get("travelled_m", 0.0)) if not active_job.is_empty() else 0.0,
        "contract_type": str(active_job.get("contract_type", "")) if not active_job.is_empty() else "",
        "time_remaining_s": float(active_job.get("time_remaining_s", 0.0)) if not active_job.is_empty() else 0.0,
    }
