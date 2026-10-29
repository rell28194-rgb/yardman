extends Node
class_name YardmanGroundcoverDensityRuntime

# Increase near-ground visual density without creating another renderer object
# per tuft. One existing grass MultiMesh remains one MultiMesh draw batch.
const TUFTS_PER_ANCHOR := 4
const MAX_SOURCE_ANCHORS_PER_CELL := 96

func _ready() -> void:
    get_tree().node_added.connect(_on_node_added)

func _on_node_added(node: Node) -> void:
    if node is MultiMeshInstance3D:
        _densify_grass_cell(node as MultiMeshInstance3D)

func _densify_grass_cell(instance: MultiMeshInstance3D) -> bool:
    if instance == null or instance.multimesh == null:
        return false
    if not str(instance.name).to_lower().ends_with("_grass"):
        return false
    if instance.get_meta("groundcover_dense", false) == true:
        return false
    var source := instance.multimesh
    var source_count := source.instance_count
    if source_count <= 0 or source_count > MAX_SOURCE_ANCHORS_PER_CELL or source.mesh == null:
        return false

    var dense := MultiMesh.new()
    dense.transform_format = MultiMesh.TRANSFORM_3D
    dense.use_colors = source.use_colors
    dense.use_custom_data = source.use_custom_data
    dense.mesh = source.mesh
    dense.instance_count = source_count * TUFTS_PER_ANCHOR

    for source_index in range(source_count):
        var base_transform := source.get_instance_transform(source_index)
        var color := source.get_instance_color(source_index) if source.use_colors else Color.WHITE
        var custom := source.get_instance_custom_data(source_index) if source.use_custom_data else Color(0.5, 0.5, 0.5, 1.0)
        var seed_phase := custom.r * TAU + float(source_index % 17) * 0.317
        for satellite in range(TUFTS_PER_ANCHOR):
            var transform := base_transform
            if satellite > 0:
                var angle := seed_phase + float(satellite) * 2.39996323
                var jitter := custom.g * 0.55 + float((source_index * 13 + satellite * 7) % 19) / 37.0
                var radius := 0.70 + float(satellite) * 0.58 + jitter
                transform.origin.x += cos(angle) * radius
                transform.origin.z += sin(angle) * radius
                var scale_jitter := 0.78 + float((source_index * 11 + satellite * 5) % 23) / 55.0
                transform.basis = Basis(Vector3.UP, angle * 0.37) * transform.basis.scaled(Vector3.ONE * scale_jitter)
            var target := source_index * TUFTS_PER_ANCHOR + satellite
            dense.set_instance_transform(target, transform)
            if dense.use_colors:
                dense.set_instance_color(target, color)
            if dense.use_custom_data:
                dense.set_instance_custom_data(target, custom)

    var source_visible := source.visible_instance_count
    instance.multimesh = dense
    # Preserve an explicit prior visibility fraction if one already exists;
    # newly built Yardman roadside cells normally use -1 until quality applies.
    if source_visible >= 0:
        var ratio := float(source_visible) / float(source_count)
        dense.visible_instance_count = clampi(int(ceil(float(dense.instance_count) * ratio)), 0, dense.instance_count)
    instance.set_meta("groundcover_dense", true)
    instance.set_meta("groundcover_source_anchors", source_count)
    instance.set_meta("groundcover_tufts_per_anchor", TUFTS_PER_ANCHOR)
    return true
