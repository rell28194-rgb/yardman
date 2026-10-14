extends Node
class_name YardmanTrafficVisualVarietyRuntime

const Catalog = preload("res://scripts/vehicle_catalog.gd")
const Styler = preload("res://scripts/vehicle_visual_styler.gd")
const UPDATE_INTERVAL := 0.25
const STYLE_IDS := ["legacy_sedan", "toyota_crown", "toyota_mark_x", "port_royal_992"]
const PAINTS := [
    [0.055, 0.070, 0.090],
    [0.16, 0.18, 0.20],
    [0.32, 0.035, 0.030],
    [0.055, 0.20, 0.31],
    [0.63, 0.64, 0.61],
    [0.12, 0.27, 0.16],
    [0.38, 0.24, 0.08],
    [0.72, 0.72, 0.76],
]

var _clock := 0.0
var _styled_models: Dictionary = {}
var _last_styled := 0

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS

func _process(delta: float) -> void:
    _clock += delta
    if _clock < UPDATE_INTERVAL:
        return
    _clock = 0.0
    _last_styled = 0
    var traffic := get_node_or_null("/root/TrafficRuntime")
    if traffic == null:
        _styled_models.clear()
        return
    var agents_value = traffic.get("agents")
    if not agents_value is Dictionary:
        return
    var agents: Dictionary = agents_value
    var live: Dictionary = {}
    var identifiers: Array = agents.keys()
    identifiers.sort()
    for identifier_value in identifiers:
        var agent: Dictionary = agents[identifier_value]
        var model_value = agent.get("model", null)
        if not model_value is Node3D or not is_instance_valid(model_value):
            continue
        var model := model_value as Node3D
        var model_id := model.get_instance_id()
        live[model_id] = true
        if _styled_models.has(model_id):
            continue
        var variant := variant_for(str(identifier_value))
        var profile := Catalog.profile(str(variant.vehicle_id)).duplicate(true)
        profile["paint_rgb"] = (variant.paint_rgb as Array).duplicate()
        var stats := Styler.apply(model, profile)
        model.set_meta("yardman_traffic_style_id", str(variant.vehicle_id))
        model.set_meta("yardman_traffic_paint_rgb", (variant.paint_rgb as Array).duplicate())
        model.set_meta("yardman_traffic_visual_stats", stats.duplicate(true))
        _styled_models[model_id] = variant.duplicate(true)
        _last_styled += 1
    var stale: Array = []
    for model_id in _styled_models.keys():
        if not live.has(model_id):
            stale.append(model_id)
    for model_id in stale:
        _styled_models.erase(model_id)

static func deterministic_seed(identifier: String) -> int:
    var value := int((identifier + "|yardman-traffic-visual-v1").hash())
    if value == -9223372036854775808:
        return 0
    return absi(value)

static func variant_for(identifier: String) -> Dictionary:
    var seed := deterministic_seed(identifier)
    var style_index := seed % STYLE_IDS.size()
    var paint_index := (seed / maxi(1, STYLE_IDS.size())) % PAINTS.size()
    return {
        "vehicle_id": STYLE_IDS[style_index],
        "paint_rgb": (PAINTS[paint_index] as Array).duplicate(),
        "style_index": style_index,
        "paint_index": paint_index,
    }

func runtime_snapshot() -> Dictionary:
    return {
        "styled_materialized_cars": _styled_models.size(),
        "newly_styled_last_pass": _last_styled,
        "style_variants": STYLE_IDS.size(),
        "paint_variants": PAINTS.size(),
    }
