extends Node3D
class_name JamaicaRoadStreamer

# Streams compact road tiles generated from OpenStreetMap / Geofabrik data.
# Geometry is stored in JAD2001 / Jamaica Metric Grid local metres.

var target: Node3D
var data_root := "res://data/roads"
var load_radius := 2
var tile_size := 4096.0
var refresh_interval := 0.25

var _refresh_clock := 0.0
var _last_tile := Vector2i(999999, 999999)
var _tile_files := {}
var _loaded := {}
var _asphalt_material: StandardMaterial3D
var _dirt_material: StandardMaterial3D

func _ready() -> void:
    _make_materials()
    _load_manifest()
    _refresh_tiles(true)

func _process(delta: float) -> void:
    if target == null or _tile_files.is_empty():
        return
    _refresh_clock += delta
    if _refresh_clock < refresh_interval:
        return
    _refresh_clock = 0.0
    _refresh_tiles(false)

func _make_materials() -> void:
    _asphalt_material = StandardMaterial3D.new()
    _asphalt_material.albedo_color = Color(0.10, 0.105, 0.11)
    _asphalt_material.roughness = 0.92

    _dirt_material = StandardMaterial3D.new()
    _dirt_material.albedo_color = Color(0.34, 0.27, 0.18)
    _dirt_material.roughness = 1.0

func _load_manifest() -> void:
    var manifest_path := "%s/manifest.json" % data_root
    if not FileAccess.file_exists(manifest_path):
        push_warning("Jamaica road manifest missing: %s" % manifest_path)
        return

    var manifest_text := FileAccess.get_file_as_string(manifest_path)
    var manifest = JSON.parse_string(manifest_text)
    if typeof(manifest) != TYPE_DICTIONARY:
        push_error("Invalid Jamaica road manifest JSON")
        return

    tile_size = float(manifest.get("tile_size", tile_size))
    for item in manifest.get("tiles", []):
        if typeof(item) != TYPE_DICTIONARY:
            continue
        var key := _tile_key(int(item.get("x", 0)), int(item.get("z", 0)))
        _tile_files[key] = str(item.get("file", ""))

    var stats = manifest.get("stats", {})
    print("Yardman Jamaica roads: %s road features, %s segments, %s tiles" % [
        str(stats.get("road_features", "?")),
        str(stats.get("segments", "?")),
        str(stats.get("tiles", "?")),
    ])

func _tile_key(tx: int, tz: int) -> String:
    return "%d:%d" % [tx, tz]

func _target_tile() -> Vector2i:
    if target == null:
        return Vector2i.ZERO
    return Vector2i(
        int(floor(target.global_position.x / tile_size)),
        int(floor(target.global_position.z / tile_size))
    )

func _refresh_tiles(force: bool) -> void:
    if target == null or _tile_files.is_empty():
        return

    var current := _target_tile()
    if not force and current == _last_tile:
        return
    _last_tile = current

    var wanted := {}
    for dz in range(-load_radius, load_radius + 1):
        for dx in range(-load_radius, load_radius + 1):
            var tx := current.x + dx
            var tz := current.y + dz
            var key := _tile_key(tx, tz)
            if _tile_files.has(key):
                wanted[key] = true
                if not _loaded.has(key):
                    _load_tile(tx, tz, key, str(_tile_files[key]))

    var unload_keys := []
    for key in _loaded.keys():
        if not wanted.has(key):
            unload_keys.append(key)
    for key in unload_keys:
        var node = _loaded[key]
        if is_instance_valid(node):
            node.queue_free()
        _loaded.erase(key)

func _load_tile(tx: int, tz: int, key: String, file_name: String) -> void:
    if file_name.is_empty():
        return
    var path := "%s/%s" % [data_root, file_name]
    if not FileAccess.file_exists(path):
        push_warning("Road tile missing: %s" % path)
        return

    var payload = JSON.parse_string(FileAccess.get_file_as_string(path))
    if typeof(payload) != TYPE_DICTIONARY:
        push_warning("Invalid road tile: %s" % path)
        return
    var segments = payload.get("segments", [])
    if segments.is_empty():
        return

    var root := Node3D.new()
    root.name = "RoadTile_%d_%d" % [tx, tz]
    root.position = Vector3(float(tx) * tile_size, 0.0, float(tz) * tile_size)
    add_child(root)

    var paved_vertices := PackedVector3Array()
    var paved_indices := PackedInt32Array()
    var dirt_vertices := PackedVector3Array()
    var dirt_indices := PackedInt32Array()
    var origin_x := float(tx) * tile_size
    var origin_z := float(tz) * tile_size

    for seg in segments:
        if typeof(seg) != TYPE_ARRAY or seg.size() < 7:
            continue
        var x1 := float(seg[0]) - origin_x
        var z1 := float(seg[1]) - origin_z
        var x2 := float(seg[2]) - origin_x
        var z2 := float(seg[3]) - origin_z
        var width := float(seg[4])
        var flags := int(seg[6])
        if (flags & 8) != 0:
            _append_road_quad(dirt_vertices, dirt_indices, x1, z1, x2, z2, width)
        else:
            _append_road_quad(paved_vertices, paved_indices, x1, z1, x2, z2, width)

    _add_surface_mesh(root, paved_vertices, paved_indices, _asphalt_material, "Paved")
    _add_surface_mesh(root, dirt_vertices, dirt_indices, _dirt_material, "Unpaved")
    _loaded[key] = root

func _append_road_quad(vertices: PackedVector3Array, indices: PackedInt32Array, x1: float, z1: float, x2: float, z2: float, width: float) -> void:
    var d := Vector2(x2 - x1, z2 - z1)
    var length := d.length()
    if length < 0.01:
        return
    d /= length
    var n := Vector2(-d.y, d.x) * (width * 0.5)
    var base := vertices.size()
    var y := 0.055
    vertices.append(Vector3(x1 + n.x, y, z1 + n.y))
    vertices.append(Vector3(x1 - n.x, y, z1 - n.y))
    vertices.append(Vector3(x2 - n.x, y, z2 - n.y))
    vertices.append(Vector3(x2 + n.x, y, z2 + n.y))
    indices.append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))

func _add_surface_mesh(parent: Node3D, vertices: PackedVector3Array, indices: PackedInt32Array, material: Material, label: String) -> void:
    if vertices.is_empty():
        return
    var arrays := []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_INDEX] = indices
    var mesh := ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    mesh.surface_set_material(0, material)
    var instance := MeshInstance3D.new()
    instance.name = label
    instance.mesh = mesh
    parent.add_child(instance)
