extends SceneTree

const Saves = preload("res://scripts/save_game.gd")
var failures := 0
var checks := 0
var max_coordinate_error_m := 0.0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    checks += 1
    if not condition:
        failures += 1
        push_error("SAVE_GAME_TEST: " + message)

func _write(path: String, text: String) -> void:
    var file := FileAccess.open(path, FileAccess.WRITE)
    _check(file != null, "fixture write failed")
    if file != null:
        file.store_string(text)
        file.close()

func _matches(actual: Dictionary, expected: Dictionary) -> bool:
    # Godot JSON parses integer schema values as floats. Compare metadata by
    # meaning and coordinates to far below a millimetre, not Variant type tags.
    if int(actual.get("schema", 0)) != int(expected.schema) or actual.get("crs") != expected.crs \
            or actual.get("in_vehicle") != expected.in_vehicle:
        return false
    for actor in ["car", "player"]:
        if not actual.get(actor) is Dictionary:
            return false
        for field in ["easting", "northing", "elevation"]:
            var difference := absf(float(actual[actor].get(field, INF)) - float(expected[actor][field]))
            max_coordinate_error_m = maxf(max_coordinate_error_m, difference)
            if not is_finite(difference) or difference > 0.00000001:
                return false
    return true

func _run() -> void:
    var directory := "user://world-save-recovery-test-%d" % Time.get_ticks_usec()
    var path := directory.path_join("world.json")
    # Coordinate values exercise large canonical eastings/northings, elevation
    # and sub-metre precision. They are a generated save fixture, not placement data.
    var old := {"schema": 1, "crs": "EPSG:3448", "in_vehicle": true,
        "car": {"easting": 650123.456789, "northing": 690456.123456, "elevation": 1234.56789},
        "player": {"easting": 650126.123456, "northing": 690459.654321, "elevation": 1235.12345}}
    _check(Saves.save_file(path, old) == OK, "first valid world save failed")
    _check(_matches(Saves.load_file(path), old), "canonical coordinates changed during round-trip")
    var next := old.duplicate(true)
    next.car.easting += 123.125
    next.car.elevation += 7.75
    _check(Saves.save_file(path, next) == OK, "second world save failed")
    _check(_matches(Saves._read_valid(path + ".bak"), old), "normal save did not retain prior checkpoint")

    _write(path, "corrupt world primary")
    _check(_matches(Saves.load_file(path), old), "corrupt primary did not recover the exact prior coordinates")
    _check(Saves._commit_staged(directory.path_join("missing.tmp"), path) != OK, "missing staged file reported success")
    _check(_matches(Saves.load_file(path), old), "failed installation after recovery lost the valid world checkpoint")

    # Recreate the recovered-primary state and perform a successful replacement.
    _check(Saves.save_file(path, next) == OK, "restoring test primary failed")
    _write(path, "corrupt world primary again")
    _check(Saves.save_file(path, next) == OK, "save after backup recovery failed")
    _check(_matches(Saves._read_valid(path + ".bak"), old), "save rotated corrupt primary over valid world backup")
    _check(_matches(Saves.load_file(path), next), "new world checkpoint did not install exactly")
    var invalid := next.duplicate(true)
    invalid.crs = "EPSG:4326"
    _check(Saves.save_file(path, invalid) == ERR_INVALID_DATA, "incorrect CRS accepted")
    invalid = next.duplicate(true)
    invalid.player.elevation = NAN
    _check(Saves.save_file(path, invalid) == ERR_INVALID_DATA, "non-finite elevation accepted")
    _check(_matches(Saves.load_file(path), next), "invalid write damaged valid canonical save")
    DirAccess.remove_absolute(path)
    _check(_matches(Saves.load_file(path), old), "missing primary did not recover prior canonical save")

    for file in DirAccess.get_files_at(directory):
        DirAccess.remove_absolute(directory.path_join(file))
    DirAccess.remove_absolute(directory)
    print("YARDMAN_SAVE_GAME_TEST %s checks=%d max_coordinate_error_m=%.12f" % ["PASS" if failures == 0 else "FAIL", checks, max_coordinate_error_m])
    quit(0 if failures == 0 else 1)
