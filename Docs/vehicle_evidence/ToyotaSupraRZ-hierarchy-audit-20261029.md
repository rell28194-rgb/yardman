# Toyota Supra RZ — source hierarchy flattening audit

Date: 2026-10-29
Source checkpoint: `Yardman-Vehicle-Production-002-Checkpoint.zip`
Legacy recovered family: `private/carx-production/recovered/ToyotaSupraRZ/`

## Result

The old source conversion is useful geometry evidence but is not a complete vehicle reconstruction.

- original serialized source objects: 170
- original GameObjects: 69
- original Transforms: 69
- named nodes in legacy LOD0 GLB: 63
- original GameObject names with an exact node-name match in GLB: 13
- original GameObjects without an exact surviving GLB node: 56

The audit was generated from the saved `source_hierarchy.json` plus the actual saved `lod0.glb`, not inferred from screenshots.

## Important source objects missing from the flattened GLB

The missing exact source GameObject set includes:

- `WheelRR`, `WheelFR`, `WheelRL`, `WheelFL`
- four `WheelCapParent` nodes
- `DriverRoot`
- `Engine`
- `PopExhaust`
- `Exhaust`
- `Cameras`
- `FrontCameraPoint`
- `RearCameraPoint`
- `FollowCameraPoint`
- `HoodCameraPoint`
- `SideCameraPoint`
- `WheelCameraPoint`
- `BumperCameraPoint`
- `DriverAssPoint`
- `UnderRoofPoint`
- `WheelsParticles`
- `Colliders`
- `Obstacle`
- numerous `Col*` collision objects
- `BodyL`
- `InteriorL`
- `LD_steering_wheel`
- `LD_interior`
- source shadow-caster nodes

Some visual semantics were recreated under new generated GLB nodes (`FrontWheelLeft`, spin nodes, `StockRim`, `StockTyre`, etc.), but that does not preserve the original runtime hierarchy or prove equivalence.

## Source data that *was* recovered and should be reused

The saved provenance proves the source already contains substantially richer dependencies than the old two-GLB promotion path used:

- source-authored wheel pivots for all four corners
- original shared CarX WheelStyle1 rim and tyre meshes
- four brake-caliper meshes
- high-detail body and glass
- high-detail interior and steering wheel
- low-detail body/interior/steering hierarchy in the raw source
- stoplight geometry
- engine / exhaust / pop-exhaust transform hierarchy
- multiple authored camera points
- collision-object hierarchy
- per-material Unity shader property records
- exterior, interior, front-light, rear-light, stoplight, wheel and brake textures

The old LOD0 export recorded 33,938 triangles / 30,221 vertices and 15 materials. The old LOD1 export recorded 13,871 triangles. These figures are conversion evidence, not a fidelity ceiling for Yardman.

## Required correction

Do not treat `lod0.glb` or `lod1.glb` as the authoritative Supra vehicle.

The new pipeline must:

1. start from the preserved raw serialized source unit and complete dependency set;
2. reconstruct the original GameObject/Transform hierarchy;
3. preserve source camera, wheel, brake, exhaust, collision, interior and LOD semantics;
4. recover source configuration/customization/upgrade/audio relationships separately rather than baking them away;
5. build a dedicated Godot vehicle hierarchy from the source descriptor;
6. keep the source-max master separate from Android runtime LODs;
7. validate customization and upgrade behavior before `HIGH-FIDELITY` or `ACCEPTED` status.

Tool added for this purpose: `Tools/vehicle_pipeline/build_hierarchy_descriptor.py`.

## Self-critique

What this audit proves: the prior exporter flattened most of the original runtime hierarchy and therefore cannot by itself reproduce the original game's complete Supra behavior.

What it does not prove: that every missing GameObject must become a unique Godot node, or that the recovered CarX source contains every upgrade/customization rule shown in the owner's newer reference video. Those rules still require source-code/config/catalog dependency recovery before implementation.
