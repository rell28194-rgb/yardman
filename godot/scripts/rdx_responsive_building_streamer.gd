extends "res://scripts/building_streamer.gd"
class_name YardmanResponsiveBuildingStreamerRDX

const RDXStreamingPriority = preload("res://scripts/streaming_priority.gd")

# R&D override: preserve the existing building wanted-set, residency caps and
# lifecycle. While the target stays in the same 256 m cell, only re-rank the
# remaining I/O queue from current position/velocity instead of leaving the
# entry-time order stale.
func update_world(x: float, z: float, force := false) -> void:
    if manifest.is_empty() or not is_finite(x) or not is_finite(z):
        return
    var next_position := Vector2(x, z)
    var current := Vector2i(floori(x / cell_size), floori(z / cell_size))
    if not force and current == _last_cell:
        _world_position = next_position
        _sort_queue_by_motion(_world_position, RDXStreamingPriority.target_velocity(target))
        return
    super.update_world(x, z, force)
