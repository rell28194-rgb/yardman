extends Node3D
class_name YardmanCoastline

const WaterShader = preload("res://shaders/water.gdshader")
const BeachShader = preload("res://shaders/beach.gdshader")
var water_material: ShaderMaterial
var beach_material: ShaderMaterial

func _init() -> void:
    water_material = ShaderMaterial.new()
    water_material.shader = WaterShader
    beach_material = ShaderMaterial.new()
    beach_material.shader = BeachShader

# Attach below the terrain tile root. The shared parent already places this
# sea-level tile relative to the floating origin, so rebase shifts it once.
func instantiate_tile(tile: Vector2i, payload: Dictionary, parent_node: Node3D, tile_size: float = 4096.0) -> void:
    append_water(payload, parent_node, float(tile.x) * tile_size, float(tile.y) * tile_size)
    append_beach(payload, parent_node, float(tile.x) * tile_size, float(tile.y) * tile_size)

func append_water(payload: Dictionary, parent_node: Node3D, world_x: float, world_z: float) -> MeshInstance3D:
    var vertices: PackedVector3Array = payload.get("water", PackedVector3Array())
    if vertices.is_empty():
        return null
    var distances: PackedFloat32Array = payload.get("shore_distance", PackedFloat32Array())
    if distances.size() != vertices.size():
        push_error("Water vertices and coastline-distance samples differ")
        return null
    var normals := PackedVector3Array()
    var uvs := PackedVector2Array()
    var colors := PackedColorArray()
    for index in vertices.size():
        normals.append(Vector3.UP)
        uvs.append(Vector2((world_x + float(vertices[index].x)) * 0.025,
            (world_z + float(vertices[index].z)) * 0.025))
        colors.append(Color(clampf(distances[index] / 40.0, 0.0, 1.0), 0.0, 0.0, 1.0))
    var instance := _instance("RegisteredOcean", vertices, normals, uvs, colors, water_material, parent_node)
    instance.extra_cull_margin = 0.15
    return instance

func append_beach(payload: Dictionary, parent_node: Node3D, world_x: float, world_z: float) -> MeshInstance3D:
    var source: PackedVector3Array = payload.get("beach", PackedVector3Array())
    if source.is_empty():
        return null
    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    var uvs := PackedVector2Array()
    for index in range(0, source.size(), 3):
        var cross := (source[index + 1] - source[index]).cross(source[index + 2] - source[index])
        if cross.length_squared() < 0.000000000001:
            continue
        var normal := cross.normalized()
        if normal.y < 0.0:
            normal = -normal
        for offset in range(3):
            var vertex := source[index + offset]
            vertex.y += 0.035
            vertices.append(vertex)
            normals.append(normal)
            uvs.append(Vector2((world_x + float(vertex.x)) * 0.2, (world_z + float(vertex.z)) * 0.2))
    return _instance("SourcedBeach", vertices, normals, uvs, PackedColorArray(), beach_material, parent_node)

func _instance(label: String, vertices: PackedVector3Array, normals: PackedVector3Array,
        uvs: PackedVector2Array, colors: PackedColorArray, material: Material, parent_node: Node3D) -> MeshInstance3D:
    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = normals
    arrays[Mesh.ARRAY_TEX_UV] = uvs
    if not colors.is_empty():
        arrays[Mesh.ARRAY_COLOR] = colors
    var mesh := ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    mesh.surface_set_material(0, material)
    var instance := MeshInstance3D.new()
    instance.name = label
    instance.mesh = mesh
    instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    parent_node.add_child(instance)
    return instance
