extends RefCounted
class_name YardmanGPUIndirectBudget

# Production-memory contract for the experimental RenderingDevice indirect path.
# Yardman's roadside renderer uses Transform3D + color + custom data, so each
# destination MultiMesh record is 20 float32 values (80 bytes).
const FLOAT_BYTES := 4
const TRANSFORM_3D_FLOATS := 12
const COLOR_FLOATS := 4
const CUSTOM_FLOATS := 4
const MULTIMESH_RECORD_BYTES := (TRANSFORM_3D_FLOATS + COLOR_FLOATS + CUSTOM_FLOATS) * FLOAT_BYTES

# The generic validation probe stores a full source record plus vec4 bounds.
# That is deliberately NOT the production roadside representation.
const GENERIC_SOURCE_BYTES := MULTIMESH_RECORD_BYTES
const GENERIC_BOUNDS_BYTES := 4 * FLOAT_BYTES

# Roadside anchors can be reconstructed from local position, yaw, scale and the
# three custom-data channels already derived on CPU. Two vec4 values preserve
# all of that without a second 80-byte MultiMesh-shaped source record.
const PACKED_ROADSIDE_SOURCE_FLOATS := 8
const PACKED_ROADSIDE_SOURCE_BYTES := PACKED_ROADSIDE_SOURCE_FLOATS * FLOAT_BYTES

# world_visuals.gd currently builds near, distant and grass MultiMeshes from the
# same anchor set. MAX_PLANTS is 1800 and quality can request road_radius=3.
const ROADSIDE_DESTINATION_LAYERS := 3
const MAX_PLANTS_PER_TILE := 1800
const MAX_ROAD_RADIUS := 3
const ROAD_RETENTION_MARGIN := 1
const MAX_PACKED_SOURCE_OVERHEAD_FRACTION := 0.15

static func square_tile_count(radius: int) -> int:
    var diameter := maxi(radius, 0) * 2 + 1
    return diameter * diameter

static func destination_bytes(anchor_count: int, tile_count: int,
        destination_layers: int = ROADSIDE_DESTINATION_LAYERS) -> int:
    return maxi(anchor_count, 0) * maxi(tile_count, 0) * maxi(destination_layers, 0) * MULTIMESH_RECORD_BYTES

static func naive_generic_total_bytes(anchor_count: int, tile_count: int,
        destination_layers: int = ROADSIDE_DESTINATION_LAYERS) -> int:
    var anchors := maxi(anchor_count, 0) * maxi(tile_count, 0)
    var layers := maxi(destination_layers, 0)
    return destination_bytes(anchor_count, tile_count, destination_layers) \
        + anchors * layers * (GENERIC_SOURCE_BYTES + GENERIC_BOUNDS_BYTES)

static func shared_full_source_total_bytes(anchor_count: int, tile_count: int,
        destination_layers: int = ROADSIDE_DESTINATION_LAYERS) -> int:
    var anchors := maxi(anchor_count, 0) * maxi(tile_count, 0)
    return destination_bytes(anchor_count, tile_count, destination_layers) \
        + anchors * (GENERIC_SOURCE_BYTES + GENERIC_BOUNDS_BYTES)

static func packed_source_total_bytes(anchor_count: int, tile_count: int,
        destination_layers: int = ROADSIDE_DESTINATION_LAYERS) -> int:
    var anchors := maxi(anchor_count, 0) * maxi(tile_count, 0)
    return destination_bytes(anchor_count, tile_count, destination_layers) \
        + anchors * PACKED_ROADSIDE_SOURCE_BYTES

static func overhead_fraction(total_bytes: int, baseline_bytes: int) -> float:
    if baseline_bytes <= 0:
        return 0.0
    return maxf(0.0, float(total_bytes - baseline_bytes) / float(baseline_bytes))

static func production_plan(load_radius: int = MAX_ROAD_RADIUS,
        include_retention_margin: bool = false) -> Dictionary:
    var radius := maxi(load_radius, 0) + (ROAD_RETENTION_MARGIN if include_retention_margin else 0)
    var tiles := square_tile_count(radius)
    var baseline := destination_bytes(MAX_PLANTS_PER_TILE, tiles)
    var naive := naive_generic_total_bytes(MAX_PLANTS_PER_TILE, tiles)
    var shared_full := shared_full_source_total_bytes(MAX_PLANTS_PER_TILE, tiles)
    var packed := packed_source_total_bytes(MAX_PLANTS_PER_TILE, tiles)
    return {
        "radius": radius,
        "tiles": tiles,
        "anchors": MAX_PLANTS_PER_TILE * tiles,
        "baseline_bytes": baseline,
        "naive_bytes": naive,
        "shared_full_bytes": shared_full,
        "packed_bytes": packed,
        "naive_overhead": overhead_fraction(naive, baseline),
        "shared_full_overhead": overhead_fraction(shared_full, baseline),
        "packed_overhead": overhead_fraction(packed, baseline),
        "packed_contract_ok": overhead_fraction(packed, baseline) <= MAX_PACKED_SOURCE_OVERHEAD_FRACTION,
    }
