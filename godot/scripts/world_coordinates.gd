extends RefCounted
class_name YardmanCoordinates

# GDScript floats are doubles. Only the final nearby Node3D transforms use
# Vector3, whose precision must never define persistent national coordinates.
var projected_origin_easting: float = 0.0
var projected_origin_northing: float = 0.0
var render_origin_x: float = 0.0
var render_origin_y: float = 0.0
var render_origin_z: float = 0.0
var tile_size: float = 4096.0

func configure(manifest: Dictionary) -> void:
    var origin: Dictionary = manifest.get("origin", {})
    projected_origin_easting = float(origin.get("easting", 0.0))
    projected_origin_northing = float(origin.get("northing", 0.0))
    tile_size = float(manifest.get("tile_size", 4096.0))

func world_to_local(x: float, z: float, y: float = 0.0) -> Vector3:
    return Vector3(x - render_origin_x, y - render_origin_y, z - render_origin_z)

func local_to_world(local: Vector3) -> PackedFloat64Array:
    return PackedFloat64Array([render_origin_x + float(local.x),
        render_origin_y + float(local.y), render_origin_z + float(local.z)])

func world_to_projected(x: float, z: float, y: float = 0.0) -> PackedFloat64Array:
    return PackedFloat64Array([projected_origin_easting + x, projected_origin_northing - z, y])

func projected_to_world(easting: float, northing: float, elevation: float = 0.0) -> PackedFloat64Array:
    return PackedFloat64Array([easting - projected_origin_easting, elevation,
        projected_origin_northing - northing])

func tile_for(x: float, z: float) -> Vector2i:
    return Vector2i(int(floor(x / tile_size)), int(floor(z / tile_size)))

func rebase(x: float, z: float, y: float = 0.0) -> Vector3:
    var shift := Vector3(render_origin_x - x, render_origin_y - y, render_origin_z - z)
    render_origin_x = x
    render_origin_y = y
    render_origin_z = z
    return shift
