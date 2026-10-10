extends Node3D
class_name YardmanCoastline

const WaterShader = preload("res://shaders/water.gdshader")
const BeachShader = preload("res://shaders/beach.gdshader")
const ReferenceAssets = preload("res://scripts/reference_assets.gd")
var water_material: ShaderMaterial
var beach_material: ShaderMaterial

func _init() -> void:
    water_material = ShaderMaterial.new()
    water_material.shader = WaterShader
    beach_material = ShaderMaterial.new()
    beach_material.shader = BeachShader
    for binding in [
        [beach_material, "reference_sand", "has_reference_sand", "beach_sand.png"],
        [water_material, "reference_surface", "has_reference_surface", "water_surface.png"],
        [water_material, "reference_foam", "has_reference_foam", "water_foam.png"],
        [water_material, "reference_caustics", "has_reference_caustics", "water_caustics.png"],
    ]:
        var texture: Texture2D = ReferenceAssets.texture(str(binding[3]))
        if texture != null:
            binding[0].set_shader_parameter(str(binding[1]), texture)
            binding[0].set_shader_parameter(str(binding[2]), true)

# Attach below the terrain tile root. The shared parent already places this
# sea-level tile relative to the floating origin, so rebase shifts it once.
func instantiate_tile(tile: Vector2i, payload: Dictionary, parent_node: Node3D, tile_size: float = 4096.0) -> void:
    append_water(payload, parent_node, float(tile.x) * tile_size, float(tile.y) * tile_size)
    append_beach(payload, parent_node, float(tile.x) * tile_size, float(tile.y) * tile_size)

func append_water(payload: Dictionary, parent_node: Node3D, world_x: float, world_z: float) -> MeshInstance3D:
    var source: PackedVector3Array = payload.get("water", PackedVector3Array())
    if source.is_empty():
        return null
    var distances: PackedFloat32Array = payload.get("shore_distance", PackedFloat32Array())
    if distances.size() != source.size() or source.size() % 3 != 0:
        push_error("Water vertices and coastline-distance samples differ")
        return null
    var normals := PackedVector3Array()
    var vertices := PackedVector3Array()
    var uvs := PackedVector2Array()
    var colors := PackedColorArray()
    for triangle in range(0, source.size(), 3):
        var cross := (source[triangle + 1] - source[triangle]).cross(source[triangle + 2] - source[triangle])
        var order := [0, 2, 1] if cross.y > 0.0 else [0, 1, 2]
        # Godot front faces are clockwise. Reorder the distance attribute with
        # each vertex; changing winding must never change the coastal tint.
        for offset: int in order:
            var index: int = triangle + offset
            var vertex := source[index]
            vertices.append(vertex)
            normals.append(Vector3.UP)
            uvs.append(Vector2((world_x + float(vertex.x)) * 0.025,
                (world_z + float(vertex.z)) * 0.025))
            colors.append(Color(clampf(distances[index] / 40.0, 0.0, 1.0), 0.0, 0.0, 1.0))
    var instance := _instance("RegisteredOcean", vertices, normals, uvs, colors, water_material, parent_node)
    instance.extra_cull_margin = 0.15
    return instance

func append_beach(payload: Dictionary, parent_node: Node3D, world_x: float, world_z: float) -> MeshInstance3D:
    var source: PackedVector3Array = payload.get("beach", PackedVector3Array())
    if source.is_empty() or source.size() % 3 != 0:
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
        var order := [0, 2, 1] if cross.dot(normal) > 0.0 else [0, 1, 2]
        for offset: int in order:
            var vertex := source[index + offset]
            vertex.y += 0.035
            vertices.append(vertex)
            normals.append(normal)
            uvs.append(Vector2((world_x + float(vertex.x)) / 3.0, (world_z + float(vertex.z)) / 3.0))
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
