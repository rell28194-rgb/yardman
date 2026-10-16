extends SceneTree

const Main = preload("res://scripts/main.gd")
const Roads = preload("res://scripts/road_streamer.gd")
const DeckCollision = preload("res://scripts/road_structure_collision.gd")
const SEAM_X := 163840.0
const WORLD_Z := -43000.0
var failures := 0

class TerrainFixture extends RefCounted:
    var height := 0.0
    var ready := true

    func height_at(_x: float, _z: float) -> float:
        return height

    func is_world_position_ready(_x: float, _z: float) -> bool:
        return ready

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("STRUCTURAL_SPAWN_TEST: " + message)

func _segment(x1: float, x2: float, y1: float, y2: float, flags: int) -> Array:
    return [x1, WORLD_Z, x2, WORLD_Z, 8.0, 4, flags, "fixture:%d:%d" % [flags, int(x1)], 0, y1, y2,
        [[x1, y1, WORLD_Z - 4.0], [x2, y2, WORLD_Z - 4.0],
         [x2, y2, WORLD_Z + 4.0], [x1, y1, WORLD_Z + 4.0]],
        [[0.0, -4.0], [x2 - x1, -4.0], [x2 - x1, 4.0], [0.0, 4.0]],
        1, 2, 16.7, 0.0, x2 - x1]

func _run() -> void:
    # Use the production collider generator with two profiled deck levels that
    # overlap in XY and continue across a national 4096 m tile boundary. This
    # catches the old unconditional DEM overwrite without depending on surveys
    # or pretending the inferred source profiles are authoritative elevations.
    var stage := Node3D.new()
    root.add_child(stage)
    var roads := Roads.new()
    roads.coordinates.rebase(SEAM_X + 3.25, WORLD_Z, 7.0)
    stage.add_child(roads)
    roads.set_process(false)
    var helper := DeckCollision.new()
    helper.roads = roads
    var terrain := TerrainFixture.new()
    var main := Main.new()
    main.roads = roads
    main.terrain = terrain
    var right_tile := Vector2i(40, -11)
    for x in [39, 40]:
        var tile := Vector2i(x, -11)
        var key := "%d:%d" % [tile.x, tile.y]
        var tile_root := Node3D.new()
        tile_root.position = roads.world_to_local(float(tile.x) * 4096.0, float(tile.y) * 4096.0)
        roads.add_child(tile_root)
        roads._loaded[key] = tile_root
        roads._tile_files[key] = "fixture"
        var x1 := SEAM_X - 10.0 if x == 39 else SEAM_X
        var x2 := SEAM_X if x == 39 else SEAM_X + 10.0
        var y1 := 12.0 if x == 39 else 12.25
        var y2 := 12.25 if x == 39 else 12.5
        helper._on_tile_content_ready(tile, tile_root,
            [_segment(x1, x2, y1, y2, 2), _segment(x1, x2, y1 - 4.0, y2 - 4.0, 4)])
    _check(helper.bridge_triangles_built == 4 and helper.tunnel_triangles_built == 4,
        "Production bridge/tunnel deck fixtures failed to generate")

    var bridge := main._spawn_support(SEAM_X, WORLD_Z, 12.45)
    var tunnel := main._spawn_support(SEAM_X, WORLD_Z, 8.45)
    _check(bridge.structural and absf(float(bridge.height) - 12.37) < 0.001,
        "Bridge save was replaced by terrain or the lower tunnel")
    _check(tunnel.structural and absf(float(tunnel.height) - 8.37) < 0.001,
        "Tunnel save was replaced by terrain or the crossing bridge")
    var under_bridge := main._spawn_support(SEAM_X, WORLD_Z, 0.05)
    _check(not under_bridge.structural and absf(float(under_bridge.height)) < 0.001,
        "Ground-level save was snapped onto a crossing deck")
    _check(not main._spawn_support(SEAM_X + 5.0, WORLD_Z + 8.0, 12.45).structural,
        "A point outside the real deck polygon received structural support")
    _check(not main._spawn_support(SEAM_X, WORLD_Z, 100.0).structural,
        "An unrelated height was pulled onto a distant deck")

    terrain.height = 40.0
    _check(absf(float(main._spawn_support(SEAM_X, WORLD_Z, 8.45).height) - 8.37) < 0.001,
        "An underground tunnel save was moved onto the mountain surface")
    terrain.height = NAN
    _check(main._spawn_support(SEAM_X, WORLD_Z, 12.45).structural,
        "A resident bridge deck could not support a save over missing terrain")
    _check(not is_finite(float(main._spawn_support(SEAM_X + 100.0, WORLD_Z, 12.45).height)),
        "An unsupported offshore save was fabricated into land")
    terrain.height = 0.0

    _check(main._collision_ready(SEAM_X, WORLD_Z), "Resident neighboring collision tiles were not ready")
    var right_key := "%d:%d" % [right_tile.x, right_tile.y]
    var right_root: Node3D = roads._loaded[right_key]
    roads._loaded.erase(right_key)
    _check(not main._collision_ready(SEAM_X, WORLD_Z),
        "A tile boundary resumed movement before its neighbor's road deck loaded")
    roads._loaded[right_key] = right_root
    terrain.ready = false
    _check(not main._collision_ready(SEAM_X, WORLD_Z), "Missing terrain collision was ignored")
    terrain.ready = true

    var actor := CharacterBody3D.new()
    actor.collision_layer = 2
    actor.collision_mask = 1
    var collision := CollisionShape3D.new()
    var shape := BoxShape3D.new()
    shape.size = Vector3(1.0, 1.0, 2.0)
    collision.shape = shape
    collision.position.y = 0.5
    actor.add_child(collision)
    stage.add_child(actor)
    actor.position = roads.world_to_local(SEAM_X + 2.0, WORLD_Z, 12.55)
    var before: PackedFloat64Array = roads.local_to_world(actor.position)
    _check(main._settle_actor_spawn(actor), "Bridge actor failed to settle")
    var settled: PackedFloat64Array = roads.local_to_world(actor.position)
    _check(absf(settled[1] - 12.77) < 0.001, "Spawn clearance or canonical/local elevation conversion is wrong")
    _check(absf(settled[0] - before[0]) < 0.001 and absf(settled[2] - before[2]) < 0.001,
        "Settling changed canonical horizontal coordinates")
    for frame in range(60):
        await physics_frame
        actor.velocity = Vector3(0.0, -1.5 if actor.is_on_floor() else maxf(actor.velocity.y - 22.0 / 60.0, -45.0), 0.0)
        actor.move_and_slide()
    _check(actor.is_on_floor(), "Restored actor never reached the real bridge collider")
    _check(absf(roads.local_to_world(actor.position)[1] - 12.42) < 0.10,
        "The restored actor fell through the bridge to terrain")

    var canonical: PackedFloat64Array = roads.local_to_world(actor.position)
    var shift: Vector3 = roads.rebase_origin(SEAM_X - 700.0, WORLD_Z + 650.0, 31.0)
    actor.position += shift
    var rebased := main._spawn_support(SEAM_X, WORLD_Z, 8.45)
    _check(rebased.structural and absf(float(rebased.height) - 8.37) < 0.001,
        "Origin rebasing changed the canonical tunnel deck height")
    _check(absf(roads.local_to_world(actor.position)[1] - canonical[1]) < 0.001,
        "Origin rebasing changed the saved actor elevation")
    _check(main._settle_actor_spawn(actor), "Actor could not settle after a nonzero vertical origin shift")

    roads._loaded.erase(right_key)
    right_root.free()
    _check(not main._spawn_support(SEAM_X + 5.0, WORLD_Z, 12.55).structural,
        "Unloaded road collision left a stale support surface")
    actor.position = roads.world_to_local(SEAM_X + 100.0, WORLD_Z, 17.0)
    _check(main._settle_actor_spawn(actor) and absf(roads.local_to_world(actor.position)[1] - 0.35) < 0.001,
        "Ordinary terrain fallback failed after rebasing")
    terrain.height = NAN
    var offshore_before: Vector3 = actor.position
    _check(not main._settle_actor_spawn(actor) and actor.position == offshore_before,
        "Unsupported recovery changed the actor before the caller could recover")

    main.free()
    helper.free()
    stage.free()
    print("YARDMAN_STRUCTURAL_SPAWN_TEST %s bridge=1 tunnel=1 stacked_decks=1 tile_seam=1 terrain_fallback=1 collision_settle=1 rebase=1 unload=1" %
        ["PASS" if failures == 0 else "FAIL"])
    quit(0 if failures == 0 else 1)
