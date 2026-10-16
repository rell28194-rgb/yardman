extends SceneTree

const Terrain = preload("res://scripts/terrain_streamer.gd")
const Roads = preload("res://scripts/road_streamer.gd")
const Visuals = preload("res://scripts/world_visuals.gd")
const TunnelGeometry = preload("res://scripts/tunnel_geometry.gd")
const DeckCollision = preload("res://scripts/road_structure_collision.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("ROAD_STRUCTURE_DATA_TEST: " + message)

func _json(path: String) -> Dictionary:
    if not FileAccess.file_exists(path):
        return {}
    var value = JSON.parse_string(FileAccess.get_file_as_string(path))
    return value if value is Dictionary else {}

func _exclude_except(node: Node, keep: StaticBody3D, result: Array[RID]) -> void:
    if node is StaticBody3D and node != keep:
        result.append((node as StaticBody3D).get_rid())
    for child in node.get_children():
        _exclude_except(child, keep, result)

func _run() -> void:
    var manifest := _json("res://data/roads/manifest.json")
    var portal_manifest := _json("res://data/roads/tunnel_portals/manifest.json")
    _check(not portal_manifest.is_empty(), "The national dataset has no compiled portal manifest")
    _check(manifest.has("structures") and manifest.has("tunnel_portals"),
        "The national road registry omitted structures or portals")
    if failures > 0:
        quit(1)
        return
    var selected: Dictionary = {}
    var selected_tile := Vector2i.ZERO
    for tile_record in portal_manifest.get("tiles", []):
        var payload := _json("res://data/roads/tunnel_portals/" + str(tile_record.file))
        for portal in payload.get("portals", []):
            var p: Array = portal.position
            var q: Array = portal.toward
            if Vector2(float(p[0]), float(p[2])).distance_to(Vector2(float(q[0]), float(q[2]))) >= 35.0:
                selected = portal
                selected_tile = Vector2i(int(tile_record.x), int(tile_record.z))
                break
        if not selected.is_empty():
            break
    _check(not selected.is_empty(), "No sufficiently long real tunnel portal exists for traversal QA")
    if selected.is_empty():
        quit(1)
        return

    var stage := Node3D.new()
    stage.name = "ActualJamaicaStructureQA"
    get_root().add_child(stage)
    var p: Array = selected.position
    var q: Array = selected.toward
    var portal := Vector2(float(p[0]), float(p[2]))
    var direction := (Vector2(float(q[0]), float(q[2])) - portal).normalized()
    var target := Node3D.new()
    stage.add_child(target)
    var terrain := Terrain.new()
    terrain.name = "JamaicaTerrainStreamer"
    terrain.data_root = "res://data/terrain"
    terrain.target = target
    terrain.visuals = Visuals.new()
    terrain.load_radius = 0
    terrain.coordinates.rebase(portal.x, portal.y, 0.0)
    stage.add_child(terrain)
    var roads := Roads.new()
    roads.name = "JamaicaRoadStreamer"
    roads.target = target
    roads.load_radius = 0
    roads.coordinates = terrain.coordinates
    stage.add_child(roads)
    var tunnel := TunnelGeometry.new()
    tunnel.name = "TunnelGeometry"
    stage.add_child(tunnel)
    var deck := DeckCollision.new()
    deck.name = "RoadStructureCollision"
    stage.add_child(deck)
    var key := "%d:%d" % [selected_tile.x, selected_tile.y]
    for frame in range(1200):
        if terrain._loaded.has(key) and roads._loaded.has(key) \
                and tunnel.portal_tiles_built > 0 and deck.tunnel_triangles_built > 0:
            break
        await process_frame
    _check(terrain._loaded.has(key) and roads._loaded.has(key), "Real portal terrain/road tiles failed to stream")
    _check(tunnel.portal_tiles_built > 0 and tunnel.tunnel_segments_built > 0,
        "Real tunnel payloads did not instantiate a terrain mask and interior shell")
    _check(tunnel.collision_triangles_removed > 0, "Real portal did not remove terrain collision")
    _check(deck.tunnel_triangles_built > 0, "Actual streamed tunnel has no independent driving deck collision")
    if not terrain._loaded.has(key) or not roads._loaded.has(key):
        stage.free()
        quit(1)
        return

    var tile_root: Node3D = terrain._loaded[key]
    var land := tile_root.get_node_or_null("RegisteredLand") as MeshInstance3D
    _check(land != null, "Real tunnel portal has no registered land mesh")
    if land != null:
        var material := land.mesh.surface_get_material(0) as ShaderMaterial
        _check(material != null and bool(material.get_shader_parameter("tunnel_portal_mask_enabled")),
            "The actual terrain material never enabled its portal discard mask")
        if material != null:
            var texture := material.get_shader_parameter("tunnel_portal_mask") as Texture2D
            _check(texture != null and texture.get_image().get_data().has(255),
                "Actual terrain mask contains no opening pixels")

    var terrain_collider: CollisionShape3D = tunnel._terrain_collision(tile_root)
    _check(terrain_collider != null, "The actual registered terrain collider is absent")
    await physics_frame
    await physics_frame
    var road_root: Node3D = roads._loaded[key]
    var deck_body := road_root.get_node_or_null("RoadStructureDeckCollision") as StaticBody3D
    _check(deck_body != null, "Real tunnel road tile has no independent deck body")
    if deck_body != null:
        var source_tile := _json("res://data/roads/tile_%d_%d.json" % [selected_tile.x, selected_tile.y])
        var tested_deck := false
        for record in source_tile.get("segments", []):
            if str(record[7]) != str(selected.edge_id) or record[11].is_empty():
                continue
            var x := 0.0
            var y := 0.0
            var z := 0.0
            for point in record[11]:
                x += float(point[0])
                y += float(point[1])
                z += float(point[2])
            var count: float = record[11].size()
            x /= count
            y = y / count + DeckCollision.DECK_COLLISION_BIAS
            z /= count
            var excluded_decks: Array[RID] = []
            _exclude_except(stage, deck_body, excluded_decks)
            var ray := PhysicsRayQueryParameters3D.create(
                terrain.coordinates.world_to_local(x, z, y + 1.0),
                terrain.coordinates.world_to_local(x, z, y - 1.0), 1, excluded_decks)
            var hit := target.get_world_3d().direct_space_state.intersect_ray(ray)
            _check(not hit.is_empty(), "Actual tunnel deck triangles do not collide")
            if not hit.is_empty():
                _check(hit.collider == deck_body and absf(float(hit.position.y) - y) < 0.03,
                    "Actual tunnel deck collision height differs from its compiled ribbon")
            tested_deck = true
            break
        _check(tested_deck, "Actual tunnel edge has no rendered driving ribbon")
    if terrain_collider != null:
        var terrain_body := terrain_collider.get_parent() as StaticBody3D
        var excluded: Array[RID] = []
        _exclude_except(stage, terrain_body, excluded)
        var probe := portal + direction * 12.0
        var y: float = terrain.height_at(probe.x, probe.y)
        _check(is_finite(y), "Real portal terrain query is not registered land")
        if is_finite(y):
            var ray := PhysicsRayQueryParameters3D.create(
                terrain.coordinates.world_to_local(probe.x, probe.y, y + 20.0),
                terrain.coordinates.world_to_local(probe.x, probe.y, y - 20.0), 1, excluded)
            var space := target.get_world_3d().direct_space_state
            _check(space.intersect_ray(ray).is_empty(), "Terrain collision still blocks the actual portal bore")
            var right := Vector2(-direction.y, direction.x)
            var outside := probe + right * (float(selected.width_m) * 0.5 + 14.0)
            var outside_y: float = terrain.height_at(outside.x, outside.y)
            _check(is_finite(outside_y), "Outside-portal terrain sample is missing")
            if is_finite(outside_y):
                ray.from = terrain.coordinates.world_to_local(outside.x, outside.y, outside_y + 20.0)
                ray.to = terrain.coordinates.world_to_local(outside.x, outside.y, outside_y - 20.0)
                _check(not space.intersect_ray(ray).is_empty(), "Portal carving removed neighboring solid terrain")

    var shell := tile_root.get_node_or_null("TunnelShell") as Node3D
    _check(shell != null, "The actual tunnel has no streamed shell")
    if shell != null:
        var before := shell.global_position
        var shift: Vector3 = roads.rebase_origin(portal.x + 1200.0, portal.y - 800.0, 30.0)
        target.position += shift
        terrain.rebase_by(shift)
        _check(shell.global_position.is_equal_approx(before + shift), "Tunnel shell rebased incorrectly")
    var portals := tunnel.portal_tiles_built
    var shells := tunnel.tunnel_segments_built
    var removed := tunnel.collision_triangles_removed
    stage.free()
    print("YARDMAN_ROAD_STRUCTURE_DATA_TEST %s actual_data=1 portal_tiles=%d shell_segments=%d removed_triangles=%d deck_collision=1 rebase=1" %
        ["PASS" if failures == 0 else "FAIL", portals, shells, removed])
    quit(0 if failures == 0 else 1)
