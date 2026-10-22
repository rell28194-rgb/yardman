extends SceneTree

const BridgeGeometry = preload("res://scripts/bridge_geometry.gd")

class FakeGraph:
    func get_edge(identifier: String) -> Dictionary:
        if identifier != "bridge-edge":
            return {}
        return {
            "id": identifier,
            "length_m": 48.0,
            "bridge": true,
            "path": [[0.0, 10.0, 0.0], [48.0, 10.0, 0.0]],
        }

class FakeRoads extends Node:
    var tile_size := 4096.0
    var graph = FakeGraph.new()

class FakeTerrain extends Node:
    var calls := 0
    func height_at(_x: float, _z: float) -> float:
        calls += 1
        return 2.0

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("BRIDGE_GEOMETRY_TEST: " + message)
    quit(1)

func _run() -> void:
    var helper := BridgeGeometry.new()
    var fake_roads := FakeRoads.new()
    var fake_terrain := FakeTerrain.new()
    helper.roads = fake_roads
    helper.terrain = fake_terrain
    var tile_root := Node3D.new()
    root.add_child(tile_root)
    var segment := [
        0.0, 0.0, 48.0, 0.0, 8.0, 1, 2, "bridge-edge", 0,
        10.0, 10.0,
        [[0.0, 10.0, -4.0], [0.0, 10.0, 4.0], [48.0, 10.0, 4.0], [48.0, 10.0, -4.0]],
        [[0.0, -4.0], [0.0, 4.0], [48.0, 4.0], [48.0, -4.0]],
        0, 2, null, 0.0, 48.0,
    ]
    helper._build_tile(Vector2i.ZERO, tile_root, [segment])
    var bridge := tile_root.get_node_or_null("BridgeGeometry")
    if bridge == null:
        _fail("bridge root was not generated")
        return
    if helper.deck_spans_built != 1 or helper.rails_built != 2 or helper.abutments_built != 2:
        _fail("deck/rail/abutment build counters are wrong")
        return
    if helper.pier_stations_built != 1 or helper.pier_columns_built != 2:
        _fail("48 m wide bridge should receive one two-column inferred pier station")
        return
    if fake_terrain.calls != 1:
        _fail("pier terrain sampling should occur once at the deterministic 24 m station")
        return
    var deck_count := bridge.find_children("BridgeDeckUnderside*", "MeshInstance3D", true, false).size()
    var rail_count := bridge.find_children("BridgeRail*", "MeshInstance3D", true, false).size()
    var abutment_count := bridge.find_children("BridgeAbutment*", "MeshInstance3D", true, false).size()
    var pier_count := bridge.find_children("BridgePier*", "MeshInstance3D", true, false).size()
    if deck_count != 1 or rail_count != 2 or abutment_count != 2 or pier_count != 2:
        _fail("bridge visual node inventory mismatch deck=%d rails=%d abutments=%d piers=%d" % [deck_count, rail_count, abutment_count, pier_count])
        return
    var collision_body := bridge.get_node_or_null("BridgeStructureCollision") as StaticBody3D
    if collision_body == null or collision_body.get_child_count() != 6:
        _fail("bridge structure collision shape count mismatch")
        return
    tile_root.free()
    helper.free()
    fake_roads.free()
    fake_terrain.free()
    print("YARDMAN_BRIDGE_GEOMETRY_TEST PASS deck=1 rails=2 abutments=2 pier_stations=1 pier_columns=2 collision_shapes=6")
    quit(0)
