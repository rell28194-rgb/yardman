#!/usr/bin/env python3
"""Generate the Yardman Toyota Probox dimensional scaffold in Blender.

Owner-provided procedural source. This is a deterministic blockout/proportion
reference, not a substitute for the final production shell. The final Probox
must still pass Yardman's normal source-fusion, interior, lighting, materials,
physics, provenance and LOD quality gates.

Coordinate convention in this generator:
- X = vehicle width
- Y = vehicle length, +Y is front
- Z = up

Nominal dimensional anchors supplied with the source:
- overall length: 4.195 m
- overall width: 1.695 m
- nominal overall height target: ~1.51 m
- wheel centers: +/-1.25 m longitudinally (~2.50 m wheelbase scaffold)
"""

import bpy
import bmesh
import math


def _principled_input(bsdf, *names):
    for name in names:
        socket = bsdf.inputs.get(name)
        if socket is not None:
            return socket
    return None


def _new_principled_material(name, base_color, roughness, transmission=0.0):
    mat = bpy.data.materials.get(name) or bpy.data.materials.new(name=name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    if bsdf:
        base = _principled_input(bsdf, "Base Color")
        rough = _principled_input(bsdf, "Roughness")
        transmit = _principled_input(bsdf, "Transmission Weight", "Transmission")
        if base:
            base.default_value = base_color
        if rough:
            rough.default_value = roughness
        if transmit:
            transmit.default_value = transmission
    return mat


def _clear_mesh_objects():
    bpy.ops.object.select_all(action="DESELECT")
    bpy.ops.object.select_by_type(type="MESH")
    bpy.ops.object.delete()


def _tag(obj, role):
    obj["yardman_vehicle"] = "Toyota Probox"
    obj["yardman_role"] = role
    obj["yardman_source"] = "owner_provided_procedural_probox_v2"


def build_accurate_probox():
    """Build the corrected owner-provided Probox procedural scaffold."""
    _clear_mesh_objects()

    body_mat = _new_principled_material(
        "Probox_Body_Paint", (0.88, 0.88, 0.90, 1.0), 0.20
    )
    plastic_mat = _new_principled_material(
        "Probox_Plastic_Trim", (0.08, 0.08, 0.08, 1.0), 0.70
    )
    glass_mat = _new_principled_material(
        "Probox_Glass", (0.05, 0.08, 0.10, 1.0), 0.05, 0.90
    )

    # Base body block. Width/length are tied to the supplied factory anchors.
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=(0, 0, 0.75))
    body = bpy.context.active_object
    body.name = "Toyota_Probox_Body"
    body.scale = (1.695, 4.195, 1.25)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    body.data.materials.append(body_mat)
    _tag(body, "body_scaffold")

    # Shape profile: sloped nose (+Y), flat wagon roof basis, vertical tailgate.
    bm = bmesh.new()
    bm.from_mesh(body.data)
    for vert in bm.verts:
        if vert.co.y > 1.1 and vert.co.z > 0.4:
            vert.co.z -= (vert.co.y - 1.1) * 0.48
        if vert.co.y < -1.8 and vert.co.z > 0.4:
            vert.co.y = -2.08
    bm.to_mesh(body.data)
    bm.free()
    body.data.update()

    # Cabin greenhouse.
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=(0, -0.1, 1.28))
    cabin = bpy.context.active_object
    cabin.name = "Probox_Cabin_Glass"
    cabin.scale = (1.55, 2.35, 0.52)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    cabin.data.materials.append(glass_mat)
    _tag(cabin, "greenhouse_scaffold")

    # Front grille.
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=(0, 2.06, 0.75))
    grille = bpy.context.active_object
    grille.name = "Probox_Grille"
    grille.scale = (0.80, 0.05, 0.22)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    grille.data.materials.append(plastic_mat)
    _tag(grille, "grille_scaffold")

    # Headlights.
    headlight_positions = [(0.62, 2.03, 0.78), (-0.62, 2.03, 0.78)]
    for index, pos in enumerate(headlight_positions, start=1):
        bpy.ops.mesh.primitive_cube_add(size=1.0, location=pos)
        headlight = bpy.context.active_object
        headlight.name = f"Probox_Headlight_{index}"
        headlight.scale = (0.32, 0.06, 0.18)
        bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
        headlight.data.materials.append(glass_mat)
        _tag(headlight, "headlight_scaffold")

    # Commercial bumpers.
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=(0, 2.11, 0.40))
    front_bumper = bpy.context.active_object
    front_bumper.name = "Probox_Front_Bumper"
    front_bumper.scale = (1.69, 0.15, 0.45)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    front_bumper.data.materials.append(plastic_mat)
    _tag(front_bumper, "front_bumper_scaffold")

    bpy.ops.mesh.primitive_cube_add(size=1.0, location=(0, -2.13, 0.40))
    rear_bumper = bpy.context.active_object
    rear_bumper.name = "Probox_Rear_Bumper"
    rear_bumper.scale = (1.69, 0.15, 0.45)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    rear_bumper.data.materials.append(plastic_mat)
    _tag(rear_bumper, "rear_bumper_scaffold")

    # Commercial steel-wheel placeholders.
    wheel_positions = [
        (0.74, 1.25, 0.31),
        (-0.74, 1.25, 0.31),
        (0.74, -1.25, 0.31),
        (-0.74, -1.25, 0.31),
    ]
    for index, pos in enumerate(wheel_positions, start=1):
        bpy.ops.mesh.primitive_cylinder_add(
            radius=0.31,
            depth=0.20,
            location=pos,
            rotation=(0, math.pi / 2, 0),
        )
        wheel = bpy.context.active_object
        wheel.name = f"Probox_Wheel_{index}"
        wheel.data.materials.append(plastic_mat)
        _tag(wheel, "wheel_scaffold")

    # Scene-level provenance and dimensional anchors for downstream tooling.
    scene = bpy.context.scene
    scene["yardman_vehicle"] = "Toyota Probox"
    scene["yardman_source"] = "owner_provided_procedural_probox_v2"
    scene["yardman_model_status"] = "dimensional_scaffold_not_final_lod0"
    scene["yardman_length_m"] = 4.195
    scene["yardman_width_m"] = 1.695
    scene["yardman_height_target_m"] = 1.51
    scene["yardman_wheelbase_scaffold_m"] = 2.50
    scene["yardman_front_axis"] = "+Y"

    print(
        "Toyota Probox procedural scaffold generated: corrected sloped nose, "
        "vertical tailgate, greenhouse, utility trim and wheel anchors."
    )
    return body


if __name__ == "__main__":
    build_accurate_probox()
