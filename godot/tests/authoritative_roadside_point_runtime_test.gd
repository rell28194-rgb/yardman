extends SceneTree

const Runtime = preload("res://scripts/authoritative_roadside_point_runtime.gd")

func _initialize() -> void:
    var lamp := Runtime.point_plan({
        "id": "n1",
        "kind": "street_lamp",
        "position": [10.0, 0.0, 20.0],
        "source_tags": {"highway": "street_lamp"},
    })
    if lamp.is_empty() or lamp.kind != "street_lamp" or lamp.point != Vector2(10.0, 20.0):
        _fail("valid OSM street lamp was rejected")
        return

    var shelter := Runtime.point_plan({
        "id": "n2",
        "kind": "bus_shelter",
        "position": [30.0, 0.0, 40.0],
        "source_tags": {"highway": "bus_stop", "shelter": "yes"},
    })
    if shelter.is_empty() or shelter.kind != "bus_shelter":
        _fail("valid OSM bus shelter was rejected")
        return

    if not Runtime.point_plan({
        "id": "n3",
        "kind": "bus_shelter",
        "position": [30.0, 0.0, 40.0],
        "source_tags": {"highway": "bus_stop", "shelter": "no"},
    }).is_empty():
        _fail("unsheltered bus stop was promoted into a shelter")
        return

    var lamp_mesh := Runtime.fallback_mesh("street_lamp")
    var shelter_mesh := Runtime.fallback_mesh("bus_shelter")
    if lamp_mesh == null or lamp_mesh.get_surface_count() < 3 or lamp_mesh.get_aabb().size.y < 6.0:
        _fail("street-lamp public fallback mesh is incomplete")
        return
    if shelter_mesh == null or shelter_mesh.get_surface_count() < 6 or shelter_mesh.get_aabb().size.x < 2.5:
        _fail("bus-shelter public fallback mesh is incomplete")
        return

    var basis := Runtime.orientation_basis(Vector2.ZERO, {"point": Vector2(0.0, 5.0)}, "n2")
    if absf(basis.determinant()) < 0.95:
        _fail("road-facing orientation basis is degenerate")
        return

    var contract := Runtime.asset_contract()
    if contract.get("position_inference", true) == true \
            or contract.get("inferred_spacing", true) == true \
            or contract.get("routing", true) == true \
            or contract.get("navigation", true) == true \
            or contract.get("collision", true) == true \
            or contract.get("procedural_public_fallback", false) != true:
        _fail("roadside point contract weakened geographic/runtime boundaries")
        return

    var payload: Variant = JSON.parse_string(FileAccess.get_file_as_string(Runtime.DATA_PATH))
    if not payload is Dictionary:
        _fail("compiled roadside point data is missing")
        return
    var stats: Dictionary = (payload as Dictionary).get("stats", {})
    if int(stats.get("points", 0)) != 38 or int(stats.get("tiles", 0)) != 18:
        _fail("compiled roadside source counts changed unexpectedly")
        return

    print("YARDMAN_AUTHORITATIVE_ROADSIDE_POINT_TEST PASS lamps=1 shelters=1 public_fallback=1 points=38 tiles=18 inferred_spacing=0")
    quit(0)

func _fail(message: String) -> void:
    push_error("YARDMAN_AUTHORITATIVE_ROADSIDE_POINT_TEST FAIL: " + message)
    quit(1)
