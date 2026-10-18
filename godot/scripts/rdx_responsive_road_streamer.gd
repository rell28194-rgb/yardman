extends "res://scripts/road_streamer.gd"
class_name YardmanResponsiveRoadStreamerRDX

const RDXStreamingPriority = preload("res://scripts/streaming_priority.gd")

# R&D override: the production streamer currently returns early while the
# target remains inside the same 4 km tile. Keep membership/lifecycle exactly
# unchanged, but re-rank any remaining queued work from the latest position and
# velocity before returning. Terrain inherits the same road-streamer scheduler.
func _refresh_tiles(force: bool) -> void:
    if target == null or _tile_files.is_empty():
        return
    var current := _target_tile()
    if not force and current == _last_tile and load_radius == _last_radius:
        _sort_queue_by_motion(_target_world_xz(), RDXStreamingPriority.target_velocity(target))
        return
    super._refresh_tiles(force)
