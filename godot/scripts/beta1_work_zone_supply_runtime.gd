extends Node
class_name YardmanBeta1WorkZoneSupplyRuntime

# Optional near-field detail for explicit OSM highway=construction work zones.
# Placement authority remains the work-zone sidecar. The recovered crate never
# uses its foreign source-map transform: one bounded presentation instance may
# be derived from an existing off-pavement cone CPU pose on selected road tiles.
const References = preload("res://scripts/reference_assets.gd")
const CRATE_FILE := "road_work_supply_crate.glb"
const SOURCE_CONTRACT := "OSM highway=construction sidecar"
const TARGET_ANCHOR := "WorkZone_Cone"
const VARIANT_MODULUS := 5
const ALONG_ROAD_OFFSET_M := 2.20
const VISIBILITY_END_M := 115.0
const VISIBILITY_FADE_M := 18.0
const INVALID_TILE := Vector2i(2147483647, 2147483647)

var _crate_mesh: ArrayMesh
var _processed: Dictionary = {}

func _ready() -> void:
    _crate_mesh = _load_crate_mesh()
    if _crate_mesh == null:
        return
    if not get_tree().node_added.is_connected(_on_node_added):
        get_tree().node_added.connect(_on_node_added)
    call_deferred("_scan_existing")

func _exit_tree() -> void:
    var tree := get_tree()
    if tree != null and tree.node_added.is_connected(_on_node_added):
        tree.node_added.disconnect(_on_node_added)

func _on_node_added(node: Node) -> void:
    if _crate_mesh != null and node.name == "Beta1WorkZones":
        call_deferred("_try_decorate_weak", weakref(node))

func _try_decorate_weak(reference: WeakRef) -> void:
    var raw: Variant = reference.get_ref()
    if raw is Node3D:
        _decorate(raw as Node3D)

func _scan_existing() -> void:
    var owner := get_parent()
    if owner == null:
        return
    var stack: Array[Node] = [owner]
    while not stack.is_empty():
        var node: Node = stack.pop_back()
        if node is Node3D and node.name == "Beta1WorkZones":
            _decorate(node as Node3D)
        for child: Node in node.get_children():
            stack.append(child)

func _decorate(work_zones: Node3D) -> void:
    if _crate_mesh == null or not eligible_root(work_zones):
        return
    var identity := work_zones.get_instance_id()
    if _processed.has(identity):
        return
    _processed[identity] = true
    var tile := tile_from_ancestors(work_zones)
    if tile == INVALID_TILE or not uses_supply_for_tile(tile):
        return
    var anchor := work_zones.get_node_or_null(TARGET_ANCHOR) as MultiMeshInstance3D
    if anchor == null:
        return
    var source_poses: Variant = anchor.get_meta("source_poses", null)
    if not valid_source_poses(source_poses):
        return
    var pose := supply_pose_from_anchor((source_poses as Array)[0] as Transform3D)
    var instance := MeshInstance3D.new()
    instance.name = "WorkZone_SupplyCrate"
    instance.mesh = _crate_mesh
    instance.transform = pose
    instance.visibility_range_end = VISIBILITY_END_M
    instance.visibility_range_end_margin = VISIBILITY_FADE_M
    instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    instance.set_meta("reference_asset", CRATE_FILE)
    instance.set_meta("placement_source", SOURCE_CONTRACT)
    instance.set_meta("presentation_inference", true)
    instance.set_meta("source_anchor_mutation", false)
    instance.set_meta("collision", false)
    instance.set_meta("navigation", false)
    work_zones.add_child(instance)

func _load_crate_mesh() -> ArrayMesh:
    var packed := References.scene(CRATE_FILE)
    if packed == null:
        return null
    var source := packed.instantiate()
    var output := ArrayMesh.new()
    _collect_surfaces(source, Transform3D.IDENTITY, output)
    source.free()
    if output.get_surface_count() == 0:
        return null
    var bounds := output.get_aabb()
    # Recovery checkpoint measured 1.6908 x 1.2888 x 1.5780 m in Godot.
    # Reject scale drift instead of silently resizing source geometry.
    if not bounds.position.is_finite() or not bounds.size.is_finite() \
            or bounds.size.x < 1.4 or bounds.size.x > 2.0 \
            or bounds.size.y < 1.0 or bounds.size.y > 1.55 \
            or bounds.size.z < 1.3 or bounds.size.z > 1.9:
        return null
    output.set_meta("reference_asset", CRATE_FILE)
    output.set_meta("source_scale_preserved", true)
    return output

func _collect_surfaces(node: Node, parent_pose: Transform3D, output: ArrayMesh) -> void:
    var pose := parent_pose
    if node is Node3D:
        pose = parent_pose * (node as Node3D).transform
    if node is MeshInstance3D:
        var instance := node as MeshInstance3D
        if instance.mesh != null:
            for surface_index in range(instance.mesh.get_surface_count()):
                var surface := SurfaceTool.new()
                surface.begin(Mesh.PRIMITIVE_TRIANGLES)
                surface.append_from(instance.mesh, surface_index, pose)
                surface.index()
                surface.commit(output)
                output.surface_set_material(output.get_surface_count() - 1, instance.get_active_material(surface_index))
    for child: Node in node.get_children():
        _collect_surfaces(child, pose, output)

static func eligible_root(work_zones: Node3D) -> bool:
    return work_zones != null and work_zones.name == "Beta1WorkZones" \
        and str(work_zones.get_meta("source_contract", "")) == SOURCE_CONTRACT \
        and bool(work_zones.get_meta("presentation_inference", false)) \
        and not bool(work_zones.get_meta("drivable", true)) \
        and not bool(work_zones.get_meta("navigation", true)) \
        and not bool(work_zones.get_meta("collision", true))

static func valid_source_poses(raw: Variant) -> bool:
    if not raw is Array or raw.is_empty():
        return false
    for value: Variant in raw:
        if not value is Transform3D:
            return false
        var pose := value as Transform3D
        if not pose.origin.is_finite() or not pose.basis.is_finite():
            return false
    return true

static func supply_pose_from_anchor(anchor: Transform3D) -> Transform3D:
    var forward := anchor.basis.z.normalized()
    if forward.length_squared() < 0.5:
        forward = Vector3.FORWARD
    return Transform3D(anchor.basis.orthonormalized(), anchor.origin + forward * ALONG_ROAD_OFFSET_M)

static func tile_from_ancestors(node: Node) -> Vector2i:
    var current := node
    while current != null:
        var label := str(current.name)
        if label.begins_with("RoadTile_"):
            var parts := label.trim_prefix("RoadTile_").split("_")
            if parts.size() == 2 and parts[0].is_valid_int() and parts[1].is_valid_int():
                return Vector2i(int(parts[0]), int(parts[1]))
        current = current.get_parent()
    return INVALID_TILE

static func uses_supply_for_tile(tile: Vector2i) -> bool:
    if tile == INVALID_TILE:
        return false
    var mixed := (tile.x * 83492791) ^ (tile.y * 2971215073)
    return posmod(mixed, VARIANT_MODULUS) == 0

static func asset_contract() -> Dictionary:
    return {
        "file": CRATE_FILE,
        "source_sha256": "01e3ff3602769c840c6c89cf20985feaad120120848d3cd483af3da1e97f7606",
        "source_dimensions_m": Vector3(1.690783, 1.288779, 1.578035),
        "placement_source": SOURCE_CONTRACT,
        "placement_anchor": TARGET_ANCHOR + " CPU source_poses",
        "max_instances_per_work_zone_tile": 1,
        "variant_modulus": VARIANT_MODULUS,
        "source_map_coordinates": false,
        "source_scale_preserved": true,
        "anchor_mutation": false,
        "collision": false,
        "navigation": false,
        "terrain_mutation": false,
        "random_jamaica_placement": false,
        "asset_absent_fallback": true,
    }
