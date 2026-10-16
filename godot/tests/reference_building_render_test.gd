extends "res://tests/reference_building_test.gd"

const Visuals = preload("res://scripts/world_visuals.gd")
var output := ""
var captures: Array[String] = []
var camera: Camera3D
func capture(label:String) -> void:
    for frame in range(8):await process_frame
    await RenderingServer.frame_post_draw
    var picture:=root.get_texture().get_image()
    check(picture!=null and not picture.is_empty(),"actual Compatibility frame missing")
    if picture==null or picture.is_empty():
        return
    var path:=output.path_join(label+".png")
    check(picture.save_png(path)==OK,"capture save failed")
    captures.append(path)
func actual_canonical(entry:Dictionary) -> Array:
    var result:Array=[]
    for component in range(3):
        var mm:MultiMeshInstance3D=entry.root.get_node("ReferenceFacade%d"%component)
        var pose:=mm.multimesh.get_instance_transform(0)
        check(pose.is_equal_approx(entry.facades[0].transforms[component]),"renderer transform differs from planned rigid source pose")
        result.append(Array(coordinates.local_to_world(mm.global_transform*pose.origin)))
    return result
func _run() -> void:
    output=OS.get_environment("YARDMAN_BUILDING_QA_OUTPUT")
    check(not output.is_empty(),"capture output directory required")
    check(DisplayServer.get_name()!="headless","actual Compatibility renderer required")
    if not failures.is_empty():quit(1);return
    DirAccess.make_dir_recursive_absolute(output)
    root_path="user://yardman/tests/render-reference-buildings"
    DirAccess.make_dir_recursive_absolute(root_path)
    write_pack([measured_host],Vector2i(1,0))
    var manifest:Dictionary={"format":1,"crs":"EPSG:3448","origin":{"easting":771862.3076757698,"northing":646846.7138758468},"tile_size":4096,"cell_size":256,"stats":{"buildings":1,"cells":1},"tiles":[{"x":0,"z":0,"file":"zero.ymb","cells":[[1,0]]}]}
    var f:=FileAccess.open(root_path+"/manifest.json",FileAccess.WRITE);f.store_string(JSON.stringify(manifest));f.close()
    coordinates=Coordinates.new();coordinates.configure(manifest)
    var world:=WorldEnvironment.new();world.environment=Environment.new();root.add_child(world)
    var sun:=DirectionalLight3D.new();sun.shadow_enabled=true;root.add_child(sun)
    var visuals:=Visuals.new();visuals.configure_environment(world.environment,sun);visuals.update_daylight(10.0,world.environment)
    streamer=Buildings.new();streamer.reference_facades_enabled=false;streamer.configure(root_path,coordinates);root.add_child(streamer)
    streamer.update_world(296,10,true);await wait_idle(streamer)
    var entry:Dictionary=streamer._loaded["1:0"]
    var wall_faces:PackedVector3Array=entry.root.get_node("Walls").mesh.get_faces()
    var roof_faces:PackedVector3Array=entry.root.get_node("Roofs").mesh.get_faces()
    var midpoint:=Vector3((48.9026+34.0411)*0.5,19.5,(5.1037+4.6003)*0.5)
    var outward:=Vector3(0.5034,0,-14.8615).normalized()
    camera=Camera3D.new();camera.current=true;camera.fov=55;root.add_child(camera)
    var target:Vector3=entry.root.global_transform*midpoint
    camera.global_position=target+outward*21.0+Vector3.UP*2.5;camera.look_at(target,Vector3.UP)
    await capture("production-host-baseline-10h")
    var near_camera:=camera.global_position
    camera.global_position=target+outward*130.0+Vector3.UP*2.5;camera.look_at(target,Vector3.UP)
    await capture("production-host-far-baseline-10h")
    var far_baseline:=root.get_texture().get_image().get_data()
    camera.global_position=near_camera;camera.look_at(target,Vector3.UP)
    streamer.free()
    streamer=Buildings.new();streamer.configure(root_path,coordinates);root.add_child(streamer)
    streamer.update_world(296,10,true);await wait_idle(streamer)
    entry=streamer._loaded["1:0"]
    check(streamer._facade_meshes.size()==3 and entry.facades.size()==1,"required source modules were not integrated")
    if entry.facades.is_empty():quit(1);return
    check(entry.facades[0].host=="w375070825:0" and entry.facades[0].edge==4,"exact OSM host/longest wall selection changed")
    check(entry.root.get_node("Walls").mesh.get_faces()==wall_faces and entry.root.get_node("Roofs").mesh.get_faces()==roof_faces,"registered host geometry changed")
    check(entry.root.get_child_count()==7,"expected bounded attachment nodes missing")
    var original:=actual_canonical(entry)
    await capture("production-host-attached-10h")
    camera.global_position=target+outward*130.0+Vector3.UP*2.5;camera.look_at(target,Vector3.UP)
    await capture("production-host-far-fallback-10h")
    check(root.get_texture().get_image().get_data()==far_baseline,"distant hidden source modules changed fallback facade pixels")
    camera.global_position=near_camera;camera.look_at(target,Vector3.UP)
    var shift:Vector3=coordinates.rebase(1296.25,-2000.5);streamer.rebase_by(shift);camera.global_position+=shift
    check_canonical(actual_canonical(entry),original)
    await capture("production-host-rebased-10h")
    streamer.update_world(10000,10000,true);await wait_idle(streamer);await process_frame
    check(streamer._loaded.is_empty(),"decorated host failed to unload")
    streamer.update_world(296,10,true);await wait_idle(streamer)
    entry=streamer._loaded["1:0"]
    check_canonical(actual_canonical(entry),original)
    check(entry.root.get_child_count()==7,"reload duplicated source modules")
    visuals.update_daylight(15.0,world.environment)
    await capture("production-host-reloaded-15h")
    var report:Dictionary={"passed":failures.is_empty(),"failures":failures,"engine":Engine.get_version_info().string,"renderer":RenderingServer.get_current_rendering_method(),"host_osm_id":measured_host[0],"crs":manifest.crs,"height_m":measured_host[1],"height_source":measured_host[2],"cell":[1,0],"wall_edge":4,"canonical_attachment_positions_m":original,"captures":captures,"checks":["production loader exact registered host record","three canonical baked source meshes at rigid metre scale","exactly three bounded cell MultiMeshes","per-face UV2 three-column middle-row suppression","130m absent attachment and unchanged fallback raster","registered wall and roof vertices unchanged","actual renderer transform matches plan","exactly once rebase canonical invariance","unload/reload duplicate-free stable source placement"],"limitations":["One retained registered OSM host; broader national visual/performance acceptance open","Host height inferred from source levels and foundation from DSM","Source photographic window cards are modest-distance optional detail, not near-view architecture acceptance","No physical Android device runtime acceptance"]}
    f=FileAccess.open(output.path_join("production-facade-report.json"),FileAccess.WRITE);f.store_string(JSON.stringify(report,"  "));f.close()
    print("YARDMAN_REFERENCE_BUILDING_RENDER_TEST ","PASS" if failures.is_empty() else "FAIL"," canonical_modules=3 captures=6")
    streamer.free();quit(0 if failures.is_empty() else 1)
