extends Node
class_name YardmanBeta1WorkZoneBraceRuntime

# Optional private-pack variation for already-sourced construction closures.
# It never creates a placement: on a bounded subset of existing WorkZone_Barrier
# MultiMeshes it substitutes the recovered Beta1 timber brace mesh while keeping
# the exact transforms, instance count and draw-batch count produced by the
# highway=construction runtime.
const References = preload("res://scripts/reference_assets.gd")
const BRACE_FILE := "building_level8_piece_1937.glb"
const TARGET_NODE := "WorkZone_Barrier"
const SOURCE_CONTRACT := "OSM highway=construction sidecar"
const INVALID_TILE := Vector2i(2147483647, 2147483647)
const VARIANT_MODULUS := 4

var _brace_mesh: ArrayMesh
var _processed: Dictionary = {}

func _ready() -> void:
    _brace_mesh = _load_brace_mesh()
    if _brace_mesh == null:
        # Public CI and private packs without the recovered component retain the
        # existing concrete-barrier presentation exactly.
        return
    if not get_tree().node_added.is_connected(_on_node_added):
        get_tree().node_added.connect(_on_node_added)
    call_deferred("_scan_existing")

func _exit_tree() -> void:
    var tree := get_tree()
    if tree != null and tree.node_added.is_connected(_on_node_added):
        tree.node_added.disconnect(_on_node_added)

func _on_node_added(node: Node) -> void:
    if _brace_mesh != null and node is MultiMeshInstance3D:
        call_deferred("_try_apply_weak", weakref(node))

func _try_apply_weak(reference: WeakRef) -> void:
    var raw: Variant = reference.get_ref()
    if raw is MultiMeshInstance3D:
        _try_apply(raw as MultiMeshInstance3D)

func _scan_existing() -> void:
    var root := get_parent()
    if root == null:
        return
    var stack: Array[Node] = [root]
    while not stack.is_empty():
        var node: Node = stack.pop_back()
        if node is MultiMeshInstance3D:
            _try_apply(node as MultiMeshInstance3D)
        for child: Node in node.get_children():
            stack.append(child)

func _try_apply(instance: MultiMeshInstance3D) -> void:
    if _brace_mesh == null or instance == null or instance.multimesh == null:
        return
    var identity := instance.get_instance_id()
    if _processed.has(identity):
        return
    if not eligible_target(instance):
        return
    var source_poses: Variant = instance.get_meta("source_poses", null)
    if not valid_source_poses(source_poses, instance.multimesh.instance_count):
        # Fail closed rather than reading renderer-owned MultiMesh transforms.
        # The work-zone runtime now retains authoritative CPU poses explicitly.
        return
    _processed[identity] = true
    var tile := tile_from_ancestors(instance)
    if tile == INVALID_TILE or not uses_brace_for_tile(tile):
        instance.set_meta("beta1_work_zone_closure_variant", "barrier")
        return
    if not apply_mesh_substitution(instance.multimesh, _brace_mesh, source_poses as Array):
        return
    instance.set_meta("beta1_work_zone_closure_variant", "timber_brace")
    instance.set_meta("reference_asset", BRACE_FILE)
    instance.set_meta("source_anchor_mutation", false)
    instance.set_meta("extra_draw_calls", false)
    instance.set_meta("building_replacement", false)

func _load_brace_mesh() -> ArrayMesh:
    var packed: PackedScene = References.scene(BRACE_FILE)
    if packed == null:
        return null
    var source := packed.instantiate()
    var raw := ArrayMesh.new()
    _collect_surfaces(source, Transform3D.IDENTITY, raw)
    source.free()
    if raw.get_surface_count() == 0:
        return null
    var bounds := raw.get_aabb()
    # Recovered source audit: approximately 9.76 x 4.0 x 3.04 m. Keep a
    # tolerant validity envelope but reject unexpected scale drift.
    if not bounds.position.is_finite() or not bounds.size.is_finite() \
            or bounds.size.x < 7.0 or bounds.size.x > 12.0 \
            or bounds.size.y < 3.0 or bounds.size.y > 5.0 \
            or bounds.size.z < 2.0 or bounds.size.z > 4.5:
        return null
    var center := Vector3(bounds.get_center().x, bounds.position.y, bounds.get_center().z)
    var correction := Transform3D(Basis.IDENTITY, -center)
    var baked := ArrayMesh.new()
    for surface_index in range(raw.get_surface_count()):
        var surface := SurfaceTool.new()
        surface.begin(Mesh.PRIMITIVE_TRIANGLES)
        surface.append_from(raw, surface_index, correction)
        surface.index()
        surface.commit(baked)
        baked.surface_set_material(baked.get_surface_count() - 1, raw.surface_get_material(surface_index))
    baked.set_meta("reference_asset", BRACE_FILE)
    baked.set_meta("source_scale_preserved", true)
    baked.set_meta("source_role", "timber_brace_frame")
    return baked

func _collect_surfaces(node: Node, parent_pose: Transform3D, output: ArrayMesh) -> void:
    var pose := parent_pose
    if node is Node3D:
        pose = parent_pose * (node as Node3D).transform
    if node is MeshInstance3D:
        var mesh_instance := node as MeshInstance3D
        if mesh_instance.mesh != null:
            for surface_index in range(mesh_instance.mesh.get_surface_count()):
                var surface := SurfaceTool.new()
                surface.begin(Mesh.PRIMITIVE_TRIANGLES)
                surface.append_from(mesh_instance.mesh, surface_index, pose)
                surface.index()
                surface.commit(output)
                output.surface_set_material(output.get_surface_count() - 1,
                    mesh_instance.get_active_material(surface_index))
    for child: Node in node.get_children():
        _collect_surfaces(child, pose, output)

static func eligible_target(instance: MultiMeshInstance3D) -> bool:
    if instance == null or instance.name != TARGET_NODE or instance.multimesh == null:
        return false
    var parent := instance.get_parent()
    return parent != null and parent.name == "Beta1WorkZones" \
        and str(parent.get_meta("source_contract", "")) == SOURCE_CONTRACT \
        and bool(parent.get_meta("presentation_inference", false)) \
        and not bool(parent.get_meta("drivable", true)) \
        and not bool(parent.get_meta("navigation", true)) \
        and not bool(parent.get_meta("collision", true))

static func tile_from_ancestors(node: Node) -> Vector2i:
    var current := node
    while current != null:
        var name := str(current.name)
        if name.begins_with("RoadTile_"):
            var parts := name.trim_prefix("RoadTile_").split("_")
            if parts.size() == 2 and parts[0].is_valid_int() and parts[1].is_valid_int():
                return Vector2i(int(parts[0]), int(parts[1]))
        current = current.get_parent()
    return INVALID_TILE

static func uses_brace_for_tile(tile: Vector2i) -> bool:
    if tile == INVALID_TILE:
        return false
    var mixed := (tile.x * 73856093) ^ (tile.y * 19349663)
    return posmod(mixed, VARIANT_MODULUS) == 0

static func valid_source_poses(raw: Variant, expected_count: int) -> bool:
    if not raw is Array or expected_count <= 0 or raw.size() != expected_count:
        return false
    for pose: Variant in raw:
        if not pose is Transform3D:
            return false
        var transform := pose as Transform3D
        if not transform.origin.is_finite() or not transform.basis.is_finite():
            return false
    return true

static func apply_mesh_substitution(multi: MultiMesh, replacement: Mesh, source_poses: Array) -> bool:
    if multi == null or replacement == null or not valid_source_poses(source_poses, multi.instance_count):
        return false
    var instance_count := multi.instance_count
    var visible_count := multi.visible_instance_count
    multi.mesh = replacement
    if multi.instance_count != instance_count:
        multi.instance_count = instance_count
    for index in range(instance_count):
        multi.set_instance_transform(index, source_poses[index] as Transform3D)
    multi.visible_instance_count = visible_count
    return multi.instance_count == instance_count and multi.visible_instance_count == visible_count

static func asset_contract() -> Dictionary:
    return {
        "file": BRACE_FILE,
        "source_role": "recovered Beta1 Level-8 timber brace frame",
        "placement_source": SOURCE_CONTRACT,
        "variant_modulus": VARIANT_MODULUS,
        "cpu_pose_authority": true,
        "renderer_pose_readback": false,
        "anchor_mutation": false,
        "instance_count_mutation": false,
        "extra_prop_nodes": false,
        "extra_draw_calls": false,
        "collision": false,
        "navigation": false,
        "terrain_mutation": false,
        "building_replacement": false,
        "source_scale_preserved": true,
        "asset_absent_fallback": true,
    }
