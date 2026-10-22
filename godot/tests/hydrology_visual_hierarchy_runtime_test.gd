extends SceneTree

const Hierarchy = preload("res://scripts/hydrology_visual_hierarchy_runtime.gd")

class FakeHydrology extends Node3D:
    func uses_compiled_dem_elevation() -> bool:
        return true

class FakeLegacyHydrology extends Node3D:
    func uses_compiled_dem_elevation() -> bool:
        return false

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("HYDROLOGY_VISUAL_HIERARCHY_RUNTIME_TEST: " + message)
    quit(1)

func _make_mesh() -> ArrayMesh:
    # Quad 0: 1.2 m wide, 6 m drop over 30 m -> steep/narrow stream.
    # Quad 1: 20 m wide, 0.2 m drop over 30 m -> broad/flat river.
    var vertices := PackedVector3Array([
        Vector3(-0.6, 20.0, 0.0), Vector3(0.6, 20.0, 0.0),
        Vector3(-0.6, 14.0, 30.0), Vector3(0.6, 14.0, 30.0),
        Vector3(40.0, 10.0, 0.0), Vector3(60.0, 10.0, 0.0),
        Vector3(40.0, 9.8, 30.0), Vector3(60.0, 9.8, 30.0),
    ])
    var normals := PackedVector3Array()
    var uvs := PackedVector2Array()
    for index in range(vertices.size()):
        normals.append(Vector3.UP)
        var quad_index := int(index / 4)
        var local := index % 4
        uvs.append(Vector2(0.0 if local in [0, 2] else 1.0, 0.0 if local < 2 else 3.75 + float(quad_index) * 0.1))
    var indices := PackedInt32Array([
        0, 2, 1, 1, 2, 3,
        4, 6, 5, 5, 6, 7,
    ])
    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = normals
    arrays[Mesh.ARRAY_TEX_UV] = uvs
    arrays[Mesh.ARRAY_INDEX] = indices
    var mesh := ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    return mesh

func _run() -> void:
    var helper := Hierarchy.new()
    var parent := FakeHydrology.new()
    root.add_child(parent)
    var instance := MeshInstance3D.new()
    instance.name = "Hydrology_0_0"
    var source := _make_mesh()
    instance.mesh = source
    parent.add_child(instance)

    var source_arrays := source.surface_get_arrays(0)
    var source_vertices: PackedVector3Array = source_arrays[Mesh.ARRAY_VERTEX]
    var source_indices: PackedInt32Array = source_arrays[Mesh.ARRAY_INDEX]
    if not helper._enrich_instance(weakref(instance)):
        _fail("v2 hydrology mesh was not enriched")
        return
    if helper.enriched_tiles != 1 or helper.enriched_quads != 2:
        _fail("enrichment counters mismatch")
        return
    if not bool(instance.get_meta("hydrology_hierarchy_enriched", false)) or int(instance.get_meta("hydrology_hierarchy_quads", 0)) != 2:
        _fail("enrichment metadata missing")
        return

    var enriched := instance.mesh as ArrayMesh
    if enriched == null or enriched.get_surface_count() != 1:
        _fail("enrichment changed one-surface batching")
        return
    var arrays := enriched.surface_get_arrays(0)
    var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
    var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
    var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
    if vertices != source_vertices or indices != source_indices:
        _fail("water hierarchy mutated compiled geometry or topology")
        return
    if colors.size() != vertices.size():
        _fail("vertex hierarchy data missing")
        return
    var stream_meta := colors[0]
    var river_meta := colors[4]
    if not (stream_meta.r < river_meta.r):
        _fail("narrow stream width class is not below broad river")
        return
    if not (stream_meta.g > river_meta.g and stream_meta.b > river_meta.b):
        _fail("steep narrow stream did not receive stronger grade/rapidness")
        return
    for index in range(4):
        if colors[index] != stream_meta or colors[index + 4] != river_meta:
            _fail("quad metadata is not constant across each ribbon")
            return
    var material := enriched.surface_get_material(0) as ShaderMaterial
    if material == null or material.shader == null or material.shader.resource_path != "res://shaders/river_surface_hierarchy.gdshader":
        _fail("hierarchy material missing")
        return

    # Legacy/v1 hydrology must remain on its existing material/mesh path.
    var legacy_parent := FakeLegacyHydrology.new()
    root.add_child(legacy_parent)
    var legacy_instance := MeshInstance3D.new()
    legacy_instance.name = "Hydrology_legacy"
    var legacy_mesh := _make_mesh()
    legacy_instance.mesh = legacy_mesh
    legacy_parent.add_child(legacy_instance)
    if helper._enrich_instance(weakref(legacy_instance)):
        _fail("legacy hydrology was unexpectedly enriched")
        return
    if legacy_instance.mesh != legacy_mesh:
        _fail("legacy hydrology mesh changed")
        return

    legacy_parent.free()
    parent.free()
    helper.free()
    print("YARDMAN_HYDROLOGY_VISUAL_HIERARCHY_RUNTIME_TEST PASS v2=1 quads=2 geometry_unchanged=1 surfaces=1 stream_fast=1 river_broad=1 legacy_untouched=1")
    quit(0)
