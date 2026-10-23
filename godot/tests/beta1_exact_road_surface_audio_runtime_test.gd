extends SceneTree

const SurfaceAudio = preload("res://scripts/beta1_exact_road_surface_audio_runtime.gd")

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("BETA1_EXACT_ROAD_SURFACE_AUDIO_TEST: " + message)
    quit(1)

func _run() -> void:
    var cases := {
        "asphalt": "asphalt",
        "chipseal": "asphalt",
        "concrete": "concrete",
        "concrete:plates": "concrete",
        "paving_stones": "cobblestone",
        "sett": "cobblestone",
        "cobblestone": "cobblestone",
        "gravel": "gravel",
        "fine_gravel": "gravel",
        "compacted": "gravel",
        "earth": "unpaved",
        "ground": "unpaved",
        "mud": "unpaved",
    }
    for raw: String in cases:
        var actual := SurfaceAudio.normalize_surface(raw, "paved")
        if actual != str(cases[raw]):
            _fail("surface normalization drifted for %s: %s" % [raw, actual])
            return
    if SurfaceAudio.normalize_surface("", "unpaved") != "unpaved":
        _fail("missing source surface did not preserve compiled unpaved fallback")
        return
    if SurfaceAudio.normalize_surface("", "paved") != "paved":
        _fail("missing source surface did not preserve compiled paved fallback")
        return
    if SurfaceAudio.normalize_surface("", "offroad") != "offroad":
        _fail("off-road fallback drifted")
        return
    if SurfaceAudio.normalize_surface("asphalt;concrete", "paved") != "asphalt":
        _fail("semicolon source surface normalization is not deterministic")
        return

    for family in ["asphalt", "concrete", "cobblestone", "paved"]:
        if SurfaceAudio.cache_key_for_family(family) != "road":
            _fail("paved family escaped the existing road voice: " + family)
            return
    for family in ["gravel", "unpaved"]:
        if SurfaceAudio.cache_key_for_family(family) != "road_gravel":
            _fail("unpaved family escaped the existing gravel voice: " + family)
            return
    for family in ["offroad", "grass", "unknown"]:
        if not SurfaceAudio.cache_key_for_family(family).is_empty():
            _fail("unsupported/off-road family gained a road-cache override: " + family)
            return

    var contract := SurfaceAudio.asset_contract()
    var files: Dictionary = contract.get("files", {})
    if str(files.get("asphalt", "")) != "road_asphalt_roll_loop.wav" \
            or str(files.get("concrete", "")) != "road_concrete_roll_loop.wav" \
            or str(files.get("cobblestone", "")) != "road_cobblestone_roll_loop.wav" \
            or str(files.get("gravel", "")) != "road_gravel_roll_loop.wav":
        _fail("recovered surface-audio filenames drifted")
        return
    if int(contract.get("voice_budget", 0)) != 4 or int(contract.get("extra_players", 99)) != 0:
        _fail("exact surface routing expanded the four-player audio budget")
        return
    if str(contract.get("source_truth", "")) != "persistent OSM road graph edge.surface":
        _fail("surface placement lost its OSM source-truth contract")
        return
    if bool(contract.get("geometry_mutation", true)) or bool(contract.get("road_class_mutation", true)) \
            or bool(contract.get("random_surface_assignment", true)):
        _fail("audio presentation gained world/road mutation authority")
        return
    if not bool(contract.get("asset_absent_fallback", false)):
        _fail("asset-absent fallback is not explicit")
        return

    print("YARDMAN_BETA1_EXACT_ROAD_SURFACE_AUDIO_TEST PASS osm_surface=1 asphalt=1 concrete=1 cobblestone=1 gravel=1 fallback=1 voices=4 extra_players=0 random=0 geometry_mutation=0")
    quit(0)
