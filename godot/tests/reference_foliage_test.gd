extends SceneTree

# Owner reference packs remain optional in public CI. Private batches must prove
# actual imported leaf alpha, opaque bark, metre normalization and baked meshes.
const References = preload("res://scripts/reference_assets.gd")
const Visuals = preload("res://scripts/world_visuals.gd")
const ASSETS = ["road_palm.glb", "road_palm_short.glb", "road_palm_curved.glb", "road_tree_near.glb", "road_palm_lod.glb", "road_tree.glb", "road_bush.glb"]
var failures := 0
var leaf_surfaces := 0
var bark_surfaces := 0
var alpha_images: Dictionary = {}
var checked_triangles := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("REFERENCE_FOLIAGE_TEST: " + message)

func _check_leaf_image(texture: Texture2D, filename: String) -> void:
    if texture == null or alpha_images.has(texture.get_instance_id()):
        return
    var source := texture.get_image()
    _check(source != null, filename + ": leaf texture has no decoded image")
    if source == null:
        return
    var image := source.duplicate() as Image
    if image.is_compressed():
        _check(image.decompress() == OK, filename + ": leaf texture cannot be inspected")
    var transparent := 0
    var opaque := 0
    for y in range(0, image.get_height(), 4):
        for x in range(0, image.get_width(), 4):
            var alpha := image.get_pixel(x, y).a
            if alpha < 0.1:
                transparent += 1
            if alpha > 0.9:
                opaque += 1
    _check(transparent > 50 and opaque > 50, filename + ": separate leaf mask was lost; atlas cards are solid rectangles")
    alpha_images[texture.get_instance_id()] = true

func _check_mesh(mesh: Mesh, filename: String) -> void:
    for surface_index in range(mesh.get_surface_count()):
        var material := mesh.surface_get_material(surface_index) as StandardMaterial3D
        _check(material != null, filename + ": imported material is missing")
        if material == null:
            continue
        var is_leaf := material.resource_name == "LA_vegetation"
        var is_bark := material.resource_name == "LA_vegetation_opaque"
        if is_leaf:
            leaf_surfaces += 1
            _check(material.albedo_color.is_equal_approx(Color.WHITE), filename + ": source desert palette tint still discolors Jamaican leaves")
            _check(material.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR, filename + ": leaf material does not use its depth-writing mask")
            _check(absf(material.alpha_scissor_threshold - 0.5) < 0.001, filename + ": source alpha cutoff changed")
            _check(material.cull_mode == BaseMaterial3D.CULL_DISABLED, filename + ": leaf card is visible from only one side")
            _check(material.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED, filename + ": source unlit leaf shader was lost")
            _check(material.albedo_texture != null, filename + ": leaf atlas is absent")
            _check_leaf_image(material.albedo_texture, filename)
        if is_bark:
            bark_surfaces += 1
            _check(material.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED, filename + ": solid trunk incorrectly uses the leaf mask")
            _check(material.cull_mode == BaseMaterial3D.CULL_BACK, filename + ": trunk culling changed")
        var arrays: Array = mesh.surface_get_arrays(surface_index)
        var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
        var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
        var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
        var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
        _check(uvs.size() == vertices.size(), filename + ": source UV0 is missing")
        if not is_bark or normals.size() != vertices.size():
            continue
        for index in range(0, indices.size(), 3):
            var a := indices[index]
            var b := indices[index + 1]
            var c := indices[index + 2]
            var cross := (vertices[b] - vertices[a]).cross(vertices[c] - vertices[a])
            var normal := normals[a] + normals[b] + normals[c]
            if cross.length_squared() < 0.000001 or normal.length_squared() < 0.000001:
                continue
            checked_triangles += 1
            _check(cross.normalized().dot(normal.normalized()) <= 0.05, filename + ": Godot trunk triangle winding opposes its outward lighting normals")

func _inspect_node(node: Node, filename: String) -> void:
    if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
        _check_mesh((node as MeshInstance3D).mesh, filename)
    for child in node.get_children():
        _inspect_node(child, filename)

func _run() -> void:
    var required := OS.get_environment("YARDMAN_REQUIRE_REFERENCE") == "1"
    if not FileAccess.file_exists(References.ROOT + "road_palm.glb"):
        _check(not required, "Required foliage batch is missing")
        print("YARDMAN_REFERENCE_FOLIAGE_TEST %s private_pack=0 fallback=1" % ("PASS" if failures == 0 else "FAIL"))
        quit(failures)
        return
    var visuals := Visuals.new()
    for filename: String in ASSETS:
        var packed: PackedScene = References.scene(filename)
        _check(packed != null, filename + ": recovered family member is missing or failed import")
        if packed == null:
            continue
        var instance := packed.instantiate()
        _inspect_node(instance, filename)
        instance.free()
        var baked: ArrayMesh = visuals._reference_plant_mesh(filename, 8.2)
        _check(baked != null, filename + ": runtime instancing bake failed")
        if baked != null:
            var bounds := baked.get_aabb()
            _check(absf(bounds.position.y) < 0.01 and absf(bounds.size.y - 8.2) < 0.02, filename + ": baking lost base-at-zero metre normalization")
            _check_mesh(baked, filename)
    _check(leaf_surfaces >= 8 and bark_surfaces >= 8, "Near foliage omitted leaves or actual trunk geometry")
    _check(not alpha_images.is_empty() and checked_triangles > 80, "Alpha or solid-trunk geometry checks did not run")
    print("YARDMAN_REFERENCE_FOLIAGE_TEST %s leaves=%d bark=%d alpha_images=%d clockwise_triangles=%d baked=1" % ["PASS" if failures == 0 else "FAIL", leaf_surfaces, bark_surfaces, alpha_images.size(), checked_triangles])
    quit(failures)
