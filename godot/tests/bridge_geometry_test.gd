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

class FakeRoads:
    var tile_size := 4096.0
    var graph = FakeGraph.new()

class FakeTerrain:
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
    helper.roads = FakeRoads.new()
    helper.terrain = FakeTerrain.new()
    var tile_root := Node3D.new()
    root.add_child(tile_root)
    # Streamed road segment contract: x0,z0,x1,z1,width,class,flags,edge,index,
    # profile Y endpoints, polygon/UV metadata, lane metadata, stations.
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
    if helper.deck_spans_built != 1:
        _fail("expected one profiled deck underside")
        return
    if helper.rails_built != 2:
        _fail("expected two collision-backed rails")
        return
    if helper.abutments_built != 2:
        _fail("true bridge endpoints did not receive both abutments")
        return
    if helper.pier_stations_built != 1 or helper.pier_columns_built != 2:
        _fail("48 m wide bridge should receive one two-column inferred pier station")
        return
    if helper.terrain.calls != 1:
        _fail("pier terrain sampling should occur once at the deterministic 24 m station")
        return
    var deck_count := bridge.find_children("BridgeDeckUnderside", "MeshInstance3D", true, false).size()
    var rail_count := bridge.find_children("BridgeRail", "MeshInstance3D", true, false).size()
    var abutment_count := bridge.find_children("BridgeAbutment", "MeshInstance3D", true, false).size()
    var pier_count := bridge.find_children("BridgePier", "MeshInstance3D", true, false).size()
    if deck_count != 1 or rail_count != 2 or abutment_count != 2 or pier_count != 2:
        _fail("bridge visual node inventory mismatch")
        return
    var collision_body := bridge.get_node_or_null("BridgeStructureCollision") as StaticBody3D
    if collision_body == null:
        _fail("bridge structure collision body missing")
        return
    # Rails + two abutments + two pier columns. Deck collision remains owned by
    # road_structure_collision.gd, so it must not be duplicated here.
    if collision_body.get_child_count() != 6:
        _fail("unexpected bridge structure collision shape count: %d" % collision_body.get_child_count())
        return
    print("YARDMAN_BRIDGE_GEOMETRY_TEST PASS deck=1 rails=2 abutments=2 pier_stations=1 pier_columns=2 collision_shapes=6")
    quit(0)
