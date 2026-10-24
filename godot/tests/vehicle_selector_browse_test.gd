extends SceneTree

const Selector = preload("res://scripts/vehicle_selector_runtime.gd")

var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if condition:
        return
    failures += 1
    push_error("VEHICLE_SELECTOR_BROWSE_TEST: " + message)

func _run() -> void:
    _check(Selector.wrapped_selection_index(0, 3, -1) == 2, "previous did not wrap from first to last")
    _check(Selector.wrapped_selection_index(2, 3, 1) == 0, "next did not wrap from last to first")
    _check(Selector.wrapped_selection_index(1, 3, 1) == 2, "next did not advance one vehicle")
    _check(Selector.wrapped_selection_index(1, 3, -1) == 0, "previous did not retreat one vehicle")
    _check(Selector.wrapped_selection_index(-1, 3, 0) == 0, "invalid selection did not normalize safely")
    _check(Selector.wrapped_selection_index(0, 0, 1) == -1, "empty fleet did not reject browse")

    var contract: Dictionary = Selector.browse_contract()
    var buttons: Array = contract.get("touch_buttons", [])
    _check(buttons == ["PreviousVehicle", "NextVehicle"], "touch browse button contract drifted")
    _check(bool(contract.get("selection_only", false)), "browsing gained live-vehicle apply authority")
    _check(str(contract.get("apply_action", "")) == "USE VEHICLE", "explicit apply action drifted")
    _check(bool(contract.get("wraparound", false)), "browse wraparound contract missing")
    _check(int(contract.get("minimum_vehicle_count", 0)) == 2, "browse enable threshold drifted")
    _check(bool(contract.get("preview_poll_compatible", false)), "workshop preview compatibility contract missing")

    var selector := Selector.new()
    selector.name = "VehicleSelectorBrowseFixture"
    root.add_child(selector)
    selector.call("_build_ui")
    await process_frame

    var previous := selector.get("_previous_button") as Button
    var next := selector.get("_next_button") as Button
    var options := selector.get("_options") as OptionButton
    var status := selector.get("_status") as Label
    _check(previous != null and previous.name == "PreviousVehicle" and previous.text == "◀ PREV", "previous touch control missing")
    _check(next != null and next.name == "NextVehicle" and next.text == "NEXT ▶", "next touch control missing")
    _check(options != null and options.name == "VehicleOptions", "vehicle option control missing")
    _check(previous != null and previous.focus_mode == Control.FOCUS_NONE, "previous button can steal mobile focus")
    _check(next != null and next.focus_mode == Control.FOCUS_NONE, "next button can steal mobile focus")

    var ids: Array[String] = ["toyota_crown", "mazda_rx7", "nissan_skyline_r34"]
    selector.set("_vehicle_ids", ids)
    if options != null:
        options.clear()
        options.add_item("Toyota Crown")
        options.add_item("Mazda RX-7")
        options.add_item("Nissan Skyline R34")
        options.select(0)
    selector.call("_update_browse_buttons")
    _check(previous != null and not previous.disabled, "previous stayed disabled with multiple vehicles")
    _check(next != null and not next.disabled, "next stayed disabled with multiple vehicles")

    var active_before := str(selector.get("_current_id"))
    selector.call("_browse_next")
    _check(options != null and options.selected == 1, "next button did not change highlighted option")
    _check(str(selector.get("_current_id")) == active_before, "browsing changed live vehicle before USE VEHICLE")
    _check(status != null and status.text.contains("tap USE VEHICLE to apply"), "browse status does not explain explicit apply")
    selector.call("_browse_previous")
    _check(options != null and options.selected == 0, "previous button did not return to first option")
    selector.call("_browse_previous")
    _check(options != null and options.selected == 2, "previous button did not wrap to last option")
    _check(str(selector.get("_current_id")) == active_before, "wraparound browse changed live vehicle")

    var single: Array[String] = ["toyota_crown"]
    selector.set("_vehicle_ids", single)
    selector.call("_update_browse_buttons")
    _check(previous != null and previous.disabled, "previous remained enabled with one vehicle")
    _check(next != null and next.disabled, "next remained enabled with one vehicle")

    selector.queue_free()
    await process_frame

    if failures == 0:
        print("YARDMAN_VEHICLE_SELECTOR_BROWSE_TEST PASS prev=1 next=1 wrap=1 touch=1 selection_only=1 explicit_apply=1 preview_compatible=1 single_disabled=1")
        quit(0)
        return
    print("YARDMAN_VEHICLE_SELECTOR_BROWSE_TEST FAIL count=%d" % failures)
    quit(1)
