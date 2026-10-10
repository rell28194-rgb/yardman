extends RefCounted
class_name YardmanCoastGeometry

# Thread-safe readers: return plain arrays, never nodes or GPU resources.
# DEM height never decides whether a cell is land.
var data_root := "res://data/coast"
var manifest: Dictionary = {}
var resolution := 65

func configure(root: String = "res://data/coast") -> bool:
    data_root = root
    var payload = JSON.parse_string(FileAccess.get_file_as_string(root + "/manifest.json"))
    if not payload is Dictionary or int(payload.get("format", 0)) != 1:
        push_error("Missing or invalid registered coastline manifest")
        return false
    manifest = payload
    resolution = int(manifest.get("resolution", 65))
    return true

func load_land_geometry(tile: Vector2i) -> Dictionary:
    return read_tile(data_root, tile, resolution)

static func _read_geometry(path: String, stride: int) -> Dictionary:
    if not FileAccess.file_exists(path):
        return {"error": "Missing coastline geometry: " + path}
    var bytes := FileAccess.get_file_as_bytes(path)
    if bytes.size() % (stride * 4 * 3) != 0:
        return {"error": "Invalid coastline triangle-list size: " + path}
    var samples := bytes.to_float32_array()
    var vertices := PackedVector3Array()
    var distances := PackedFloat32Array()
    for index in range(0, samples.size(), stride):
        var vertex := Vector3(samples[index], samples[index + 1], samples[index + 2])
        if not vertex.is_finite():
            return {"error": "Non-finite coastline geometry: " + path}
        vertices.append(vertex)
        if stride == 4:
            if not is_finite(samples[index + 3]):
                return {"error": "Non-finite coastline shore distance: " + path}
            distances.append(samples[index + 3])
    return {"vertices": vertices, "distances": distances}

static func _read_payload(root: String, suffix: String, expected_mask_size: int) -> Dictionary:
    var mask_path := root + "/mask_" + suffix + ".bin"
    if not FileAccess.file_exists(mask_path):
        return {"error": "Missing coastline cell mask: " + mask_path}
    var mask := FileAccess.get_file_as_bytes(mask_path)
    if mask.size() != expected_mask_size:
        return {"error": "Wrong coastline cell-mask size: " + mask_path}
    for value in mask:
        if value > 2:
            return {"error": "Unknown coastline cell classification: " + mask_path}
    var land := _read_geometry(root + "/land_" + suffix + ".bin", 3)
    var water := _read_geometry(root + "/water_" + suffix + ".bin", 4)
    var beach := _read_geometry(root + "/beach_" + suffix + ".bin", 3)
    for geometry in [land, water, beach]:
        if geometry.has("error"):
            return geometry
    return {"mask": mask, "land": land.vertices, "water": water.vertices,
        "shore_distance": water.distances, "beach": beach.vertices}

static func read_tile(root: String, tile: Vector2i, terrain_resolution: int = 65) -> Dictionary:
    return _read_payload(root, "%d_%d" % [tile.x, tile.y], (terrain_resolution - 1) * (terrain_resolution - 1))

static func read_overview(root: String, width: int, depth: int) -> Dictionary:
    var mask_path := root + "/overview_mask.bin"
    if not FileAccess.file_exists(mask_path):
        return {"error": "Missing overview coastline mask"}
    var mask := FileAccess.get_file_as_bytes(mask_path)
    if mask.size() != (width - 1) * (depth - 1):
        return {"error": "Invalid overview coastline mask size"}
    for value in mask:
        if value > 2:
            return {"error": "Unknown overview coastline cell classification"}
    var land := _read_geometry(root + "/overview_land.bin", 3)
    var water := _read_geometry(root + "/overview_water.bin", 4)
    if land.has("error"):
        return land
    if water.has("error"):
        return water
    return {"mask": mask, "land": land.vertices, "water": water.vertices,
        "shore_distance": water.distances, "beach": PackedVector3Array()}

static func contains_land(payload: Dictionary, x: float, z: float, spacing: float, terrain_resolution: int = 65) -> bool:
    var cells := terrain_resolution - 1
    var ix := int(floor(x / spacing))
    var iz := int(floor(z / spacing))
    if ix < 0 or iz < 0 or ix >= cells or iz >= cells:
        return false
    var mask: PackedByteArray = payload.get("mask", PackedByteArray())
    if mask.size() != cells * cells:
        return false
    var classification := int(mask[iz * cells + ix])
    if classification == 1:
        return true
    if classification == 0:
        return false
    var vertices: PackedVector3Array = payload.get("land", PackedVector3Array())
    var point := Vector2(x, z)
    for index in range(0, vertices.size(), 3):
        var a := Vector2(vertices[index].x, vertices[index].z)
        var b := Vector2(vertices[index + 1].x, vertices[index + 1].z)
        var c := Vector2(vertices[index + 2].x, vertices[index + 2].z)
        var s1 := (b - a).cross(point - a)
        var s2 := (c - b).cross(point - b)
        var s3 := (a - c).cross(point - c)
        if (s1 >= -0.0001 and s2 >= -0.0001 and s3 >= -0.0001) or (s1 <= 0.0001 and s2 <= 0.0001 and s3 <= 0.0001):
            return true
    return false
