extends SceneTree

var failures := 0

const REQUIRED_EXPORTS := [
    "data/roads/*.json",
    "data/roads/graph/*.json",
    "data/roads/graph/*.ymr",
    "data/roads/structures/*.json",
    "data/roads/tunnel_portals/*.json",
    "data/roads/roadworks/*.json",
    "data/roads/drainage/*.json",
    "data/roads/fences/*.json",
    "data/roads/streetlights/*.json",
    "data/roads/guardrails/*.json",
    "data/roads/retaining_walls/*.json",
    "data/roads/bus_stops/*.json",
    "data/places/*.json",
    "data/parishes/*.json",
    "data/terrain/*.json",
    "data/terrain/*.bin",
    "data/coast/*.json",
    "data/coast/*.bin",
    "data/buildings/*.json",
    "data/buildings/*.ymb",
]

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if condition:
        return
    failures += 1
    push_error("EXPORT_DATA_CONTRACT_TEST: " + message)

func _run() -> void:
    var config := ConfigFile.new()
    _check(config.load("res://export_presets.cfg") == OK, "Android export preset could not be loaded")
    var export_filter := str(config.get_value("preset.0", "export_filter", ""))
    _check(export_filter == "all_resources", "Android export must retain Godot resources")
    var include_raw := str(config.get_value("preset.0", "include_filter", ""))
    var includes := {}
    for item in include_raw.split(",", false):
        includes[item.strip_edges()] = true
    for required in REQUIRED_EXPORTS:
        _check(includes.has(required), "missing runtime data export pattern: " + required)
    print("YARDMAN_EXPORT_DATA_CONTRACT_TEST %s required_patterns=%d" % ["PASS" if failures == 0 else "FAIL", REQUIRED_EXPORTS.size()])
    quit(0 if failures == 0 else 1)
