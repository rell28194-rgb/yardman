extends SceneTree

const Coordinates = preload("res://scripts/world_coordinates.gd")
const Buildings = preload("res://scripts/building_streamer.gd")
var failures: Array[String] = []
var measured_host: Array = ["w375070825:0",9.8,2,3,24.12863,[[[33.549,13.94006,19.0335],[44.5921,13.63076,19.4079],[48.3999,13.69941,19.5369],[48.5419,13.63384,15.4581],[48.9026,13.91239,5.1037],[34.0411,14.32863,4.6003]]],[[34.0411,4.6003],[48.3999,19.5369],[48.9026,5.1037],[33.549,19.0335]],[0,1,2,1,0,3]]
var streamer
var coordinates
var root_path := "user://yardman/tests/reference-buildings"
func _initialize() -> void: call_deferred("_run")
func check(ok: bool, why: String) -> void:
    if not ok:
        failures.append(why)
        push_error("REFERENCE_BUILDING_TEST: " + why)
func wait_idle(node) -> void:
    for frame in range(600):
        await process_frame
        if node.is_idle(): return
    check(false,"streamer timeout")
func write_pack(records: Array, local_cell := Vector2i.ZERO) -> void:
    var bytes := JSON.stringify(records).to_utf8_buffer().compress(FileAccess.COMPRESSION_GZIP)
    var f:=FileAccess.open(root_path+"/zero.ymb",FileAccess.WRITE)
    f.store_buffer("YMB1".to_ascii_buffer()); f.store_32(1)
    f.store_16(local_cell.x); f.store_16(local_cell.y); f.store_32(20); f.store_32(bytes.size()); f.store_buffer(bytes); f.close()
func canonical(entry: Dictionary) -> Array:
    var result: Array = []
    for component in range(3):
        var mm: MultiMeshInstance3D = entry.root.get_node("ReferenceFacade%d" % component)
        var pose:Transform3D = entry.facades[0].transforms[component]
        result.append(Array(coordinates.local_to_world(mm.global_transform * pose.origin)))
    return result
func check_canonical(actual: Array, expected: Array) -> void:
    for index in range(actual.size()):
        for axis in range(3):
            check(absf(float(actual[index][axis])-float(expected[index][axis])) < 0.001,"canonical position changed")
func _run() -> void:
    DirAccess.make_dir_recursive_absolute(root_path)
    write_pack([measured_host])
    var manifest := {"format":1,"crs":"EPSG:3448","origin":{"easting":771862.3076757698,"northing":646846.7138758468},"tile_size":4096,"cell_size":256,"stats":{"buildings":1,"cells":1},"tiles":[{"x":0,"z":0,"file":"zero.ymb","cells":[[0,0]]}]}
    var f:=FileAccess.open(root_path+"/manifest.json",FileAccess.WRITE);f.store_string(JSON.stringify(manifest));f.close()
    coordinates=Coordinates.new(); coordinates.configure(manifest)
    var fallback=Buildings.new();fallback.reference_facades_enabled=false;fallback.configure(root_path,coordinates)
    root.add_child(fallback);fallback.update_world(40,10,true);await wait_idle(fallback)
    var baseline:Dictionary=fallback._loaded["0:0"]
    var wall_faces:PackedVector3Array=baseline.root.get_node("Walls").mesh.get_faces()
    var roof_faces:PackedVector3Array=baseline.root.get_node("Roofs").mesh.get_faces()
    var wall_uvs:PackedVector2Array=baseline.root.get_node("Walls").mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV]
    for mask:Vector2 in baseline.root.get_node("Walls").mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV2]: check(mask==Buildings.NO_FACADE_MASK,"disabled facade suppressed fallback window")
    check(baseline.root.get_child_count()==3,"disabled facade created attachment nodes")
    fallback.free()
    streamer=Buildings.new();streamer.configure(root_path,coordinates);root.add_child(streamer)
    streamer.update_world(40,10,true);await wait_idle(streamer)
    var entry:Dictionary=streamer._loaded["0:0"]
    var available:bool=streamer._facade_meshes.size()==3
    check(OS.get_environment("YARDMAN_REQUIRE_REFERENCE")!="1" or available,"required canonical source facade media missing")
    check(entry.root.get_node("Walls").mesh.get_faces()==wall_faces,"source facade changed host wall geometry")
    check(entry.root.get_node("Roofs").mesh.get_faces()==roof_faces,"source facade changed host roof geometry")
    check(entry.root.get_node("Walls").mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV]==wall_uvs,"source facade changed host surface UVs")
    if available:
        check(entry.facades.size()==1 and entry.facades[0].host==measured_host[0] and entry.facades[0].edge==4,"deterministic longest eligible source wall changed")
        check(entry.root.get_child_count()==7,"cell did not batch exactly three source meshes and one bay body")
        var masks:PackedVector2Array=entry.root.get_node("Walls").mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV2]
        for index in range(masks.size()):
            check(masks[index]==(Vector2(entry.facades[0].first_column,1) if floori(float(index)/4.0)==4 else Buildings.NO_FACADE_MASK),"mask leaked beyond selected external wall")
        var polygon := PackedVector2Array()
        for point:Array in measured_host[5][0]:polygon.append(Vector2(point[0],point[2]))
        for component in range(3):
            var mm:MultiMeshInstance3D=entry.root.get_node("ReferenceFacade%d"%component)
            check(mm.multimesh.mesh==streamer._facade_meshes[component] and mm.multimesh.instance_count==1,"cached mesh or instance count changed")
            check(mm.visibility_range_end==100.0,"attachment distance is unbounded")
            var pose:Transform3D=entry.facades[0].transforms[component]
            check(pose.basis.is_equal_approx(pose.basis.orthonormalized()) and absf(pose.basis.determinant()-1.0)<0.0001,"source component rescaled/reflected")
            var wall_point:=pose.origin-pose.basis.z*0.4
            check(Geometry2D.is_point_in_polygon(Vector2(wall_point.x,wall_point.z),polygon),"source exterior faces inward")
            var bounds:=mm.multimesh.mesh.get_aabb()
            check(pose.origin.y+bounds.position.y>14.32863+0.3 and pose.origin.y+bounds.end.y<24.12863-0.3,"source component violates host height fit")
            var arrays:=mm.multimesh.mesh.surface_get_arrays(0)
            check(arrays[Mesh.ARRAY_TEX_UV]!=null and arrays[Mesh.ARRAY_NORMAL]!=null,"bake lost source UV/normals")
            var material:=mm.multimesh.mesh.surface_get_material(0) as StandardMaterial3D
            check(material!=null and material.albedo_texture!=null,"bake lost source texture")
        var before:=canonical(entry)
        for frame in range(3):await physics_frame
        var pose:Transform3D=entry.facades[0].transforms[1]
        var center:Vector3=entry.root.global_transform*(pose*streamer._facade_meshes[1].get_aabb().get_center())
        var ray:=PhysicsRayQueryParameters3D.create(center+pose.basis.z,center-pose.basis.z,1)
        var hit:Dictionary=streamer.get_world_3d().direct_space_state.intersect_ray(ray)
        check(not hit.is_empty() and hit.collider==entry.facade_body,"measured projecting bay collision absent")
        ray=PhysicsRayQueryParameters3D.create(center+pose.basis.z*2,center-pose.basis.z*2,1)
        ray.exclude=[entry.facade_body.get_rid()]
        check(not streamer.get_world_3d().direct_space_state.intersect_ray(ray).is_empty(),"registered host wall collision absent")
        streamer.update_world(760,10,true);await wait_idle(streamer);await process_frame
        check(entry.facade_body.collision_layer==0,"distant bay retained active collision")
        streamer.update_world(40,10,true);await wait_idle(streamer)
        var shift:Vector3=coordinates.rebase(1000.25,-2000.5);streamer.rebase_by(shift)
        check_canonical(canonical(entry),before)
        streamer.update_world(10000,10000,true);await wait_idle(streamer);await process_frame
        check(streamer._loaded.is_empty(),"decorated cell failed to unload")
        streamer.update_world(40,10,true);await wait_idle(streamer)
        entry=streamer._loaded["0:0"];check_canonical(canonical(entry),before)
        check(entry.root.get_child_count()==7,"reload duplicated attachments")
        streamer.free()
        var records:Array=[]
        for index in range(40):
            var record:Array=measured_host.duplicate(true);record[0]="budget-host-%d"%index;records.append(record)
        write_pack(records)
        streamer=Buildings.new();streamer.configure(root_path,coordinates);root.add_child(streamer)
        streamer.update_world(40,10,true);await wait_idle(streamer)
        entry=streamer._loaded["0:0"]
        check(entry.facades.size()==32 and entry.facade_body.get_child_count()==32,"32-host cell bound exceeded")
        for component in range(3):check(entry.root.get_node("ReferenceFacade%d"%component).multimesh.instance_count==32,"bounded cell batching changed")
        var budget_masks:PackedVector2Array=entry.root.get_node("Walls").mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV2]
        for index in range(32*24,budget_masks.size()):check(budget_masks[index]==Buildings.NO_FACADE_MASK,"host budget suppressed unattached fallback windows")
    else:
        check(entry.root.get_child_count()==3 and entry.facades.is_empty(),"absent media created attachment nodes")
        for mask:Vector2 in entry.root.get_node("Walls").mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV2]:check(mask==Buildings.NO_FACADE_MASK,"absent media suppressed inferred windows")
    print("YARDMAN_REFERENCE_BUILDING_TEST ","PASS" if failures.is_empty() else "FAIL"," source_media=",available," registered_geometry=1 bounds=1 fallback=1")
    streamer.free();quit(0 if failures.is_empty() else 1)
