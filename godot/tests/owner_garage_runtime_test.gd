extends SceneTree

const Catalog = preload("res://scripts/vehicle_catalog.gd")
const References = preload("res://scripts/reference_assets.gd")

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("OWNER_GARAGE_RUNTIME: " + message)
    quit(1)

func _run() -> void:
    var packaged := 0
    for raw_id in Catalog.production_ids():
        var hero := Catalog.hero_scene(str(raw_id))
        var packaged_path := References.packaged_scene_path(hero)
        if not packaged_path.is_empty() and ResourceLoader.exists(packaged_path):
            packaged += 1
    if packaged != 64:
        _fail("export-visible packaged fleet count=%d expected=64" % packaged)
        return

    var err := change_scene_to_file("res://main.tscn")
    if err != OK:
        _fail("main scene failed to load: %s" % err)
        return
    for _i in range(20):
        await process_frame
    var game := current_scene
    if game == null:
        _fail("main scene missing after load")
        return
    var controller = game.get("vehicle")
    if controller == null:
        _fail("vehicle controller missing")
        return
    var body = controller.get("body")
    if not body is CharacterBody3D:
        _fail("vehicle body missing")
        return
    if not bool(body.get_meta("yardman_vehicle_identity_valid", false)):
        _fail("boot vehicle fell back instead of loading exact Crown")
        return
    if str(body.get_meta("yardman_vehicle_identity", "")) != Catalog.DEFAULT_ID:
        _fail("boot vehicle identity is not toyota_crown")
        return
    var boot_visual = controller.get("visual")
    if boot_visual == null or not bool(boot_visual.get_meta("yardman_dedicated_vehicle_mesh", false)):
        _fail("boot Crown is not a dedicated fleet mesh")
        return
    if str(boot_visual.get_meta("yardman_requested_hero_scene", "")) != "toyota_crown_2013.glb":
        _fail("boot Crown did not request exact Crown hero")
        return

    var garage := root.get_node_or_null("VehicleGarage")
    if garage == null:
        _fail("VehicleGarage autoload missing")
        return
    for _i in range(20):
        await process_frame
    var ids: Array = garage.get("_vehicle_ids")
    if ids.size() != 64:
        _fail("garage selector count=%d expected=64" % ids.size())
        return
    var button = garage.get("_button")
    if button == null or not str(button.text).begins_with("GARAGE"):
        _fail("GARAGE control missing")
        return
    var current := str(garage.get("_current_id"))
    if current != "toyota_crown":
        _fail("default vehicle=%s expected toyota_crown" % current)
        return
    if not bool(garage.call("_apply_vehicle", "audi_r8", false)):
        _fail("Crown -> Audi R8 runtime switch failed")
        return
    if str(garage.get("_current_id")) != "audi_r8":
        _fail("Audi R8 not active after switch")
        return
    if not bool(garage.call("_apply_vehicle", "toyota_crown", false)):
        _fail("Audi R8 -> Crown runtime switch failed")
        return
    if str(garage.get("_current_id")) != "toyota_crown":
        _fail("Crown not restored after switch")
        return
    var restored = controller.get("visual")
    if restored == null or str(restored.get_meta("yardman_requested_hero_scene", "")) != "toyota_crown_2013.glb":
        _fail("restored Crown is not exact Crown hero")
        return
    print("YARDMAN_OWNER_GARAGE_RUNTIME_PASS selector=64 default=toyota_crown switch=toyota_crown>audi_r8>toyota_crown packaged=64 exact_crown=1")
    quit(0)