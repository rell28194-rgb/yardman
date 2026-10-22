extends SceneTree

const TunnelGeometry = preload("res://scripts/tunnel_geometry.gd")

class FakeTerrain extends Node:
    var tile_size := 64.0

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("TUNNEL_GEOMETRY_RUNTIME_TEST: " + message)
    quit(1)

func _run() -> void:
    var helper := TunnelGeometry.new()
    helper.terrain = FakeTerrain.new()
    var tile_root := Node3D.new()
    root.add_child(tile_root)

    var portals := [{
        "position": [5.0, 20.0, 5.0],
        "toward": [30.0, 18.0, 5.0],
        "width_m": 7.0,
        "source_way": "w10",
        "node_id": "osm:1",
        "layer": -1,
    }]
    var prepared := helper._prepare_portals(Vector2i.ZERO, portals)
    if prepared.size() != 1:
        _fail("portal geometry was not prepared")
        return
    if not helper._inside_portal(Vector2(10.0, 5.0), prepared[0]):
        _fail("portal opening does not contain the tunnel approach")
        return
    if helper._inside_portal(Vector2(10.0, 20.0), prepared[0]):
        _fail("portal opening is too wide")
        return

    helper._build_portal_facades(Vector2i.ZERO, tile_root, portals)
    var facades := tile_root.get_node_or_null("TunnelPortalFacades")
    if facades == null or facades.get_child_count() != 1:
        _fail("portal facade root missing")
        return
    if helper.portal_facades_built != 1 or helper.portal_lights_built != 1:
        _fail("portal facade/light counters failed")
        return
    var portal_body := facades.get_child(0) as StaticBody3D
    if portal_body == null:
        _fail("portal structure is not collision-backed")
        return
    var portal_meshes := portal_body.find_children("*Visual_*", "MeshInstance3D", true, false)
    var portal_colliders := portal_body.find_children("*Collision_*", "CollisionShape3D", true, false)
    var portal_lights := portal_body.find_children("PortalLight_*", "OmniLight3D", true, false)
    if portal_meshes.size() != 3 or portal_colliders.size() != 3 or portal_lights.size() != 1:
        _fail("portal facade inventory mismatch meshes=%d colliders=%d lights=%d" % [portal_meshes.size(), portal_colliders.size(), portal_lights.size()])
        return
    var entrance_light := portal_lights[0] as OmniLight3D
    if entrance_light.shadow_enabled or entrance_light.omni_range > 14.0:
        _fail("portal light violates mobile budget")
        return

    var tunnels := [{
        "a": [5.0, 18.0, 5.0],
        "b": [55.0, 16.0, 5.0],
        "width_m": 7.0,
        "edge_id": "tunnel-edge",
    }]
    helper._build_tunnel_shell(Vector2i.ZERO, tile_root, tunnels)
    var shell := tile_root.get_node_or_null("TunnelShell")
    if shell == null or shell.get_child_count() != 1:
        _fail("tunnel shell missing")
        return
    if helper.tunnel_segments_built != 1:
        _fail("tunnel segment counter failed")
        return
    if helper.interior_lights_built != 2:
        _fail("50 m tunnel segment should receive two bounded interior lights")
        return
    var body := shell.get_child(0) as StaticBody3D
    if body == null:
        _fail("tunnel shell is not collision-backed")
        return
    var interior_meshes := body.find_children("TunnelStructureVisual_*", "MeshInstance3D", true, false)
    var interior_colliders := body.find_children("TunnelStructureCollision_*", "CollisionShape3D", true, false)
    var interior_lights := body.find_children("TunnelLight_*", "OmniLight3D", true, false)
    if interior_meshes.size() != 3 or interior_colliders.size() != 3 or interior_lights.size() != 2:
        _fail("tunnel shell inventory mismatch meshes=%d colliders=%d lights=%d" % [interior_meshes.size(), interior_colliders.size(), interior_lights.size()])
        return
    for raw_light in interior_lights:
        var light := raw_light as OmniLight3D
        if light == null or light.shadow_enabled or light.omni_range > 14.0:
            _fail("interior light violates mobile budget")
            return

    tile_root.free()
    helper.terrain.free()
    helper.free()
    print("YARDMAN_TUNNEL_GEOMETRY_RUNTIME_TEST PASS portal=1 portal_light=1 shell=1 interior_lights=2 collision=6 terrain_mutation=0")
    quit(0)
