# Yardman execution authority

Yardman is the active/default project. If the owner says only `continue`, resume Yardman unless the owner explicitly names another project in that conversation.

Canonical execution lane: `codex/yardman-vehicle-master-20261029`.
This lane was created from the live `codex/world-reconciliation-001` head observed on 2026-10-29. Re-fetch the live branch head before every write; never assume a historical SHA is still current.

Engine: Godot 4.7.2 Compatibility renderer.
Primary runtime: Yardman/Godot only.
Primary platform: Android.
World scope: full Jamaica at 1:1 metre scale, all 14 parishes, EPSG:3448 registration, streaming/LOD/origin rebasing mandatory.
PR #4 remains unmerged unless the owner explicitly orders otherwise.

## Source authority

The authoritative donor universe is the owner's Google Drive source set, not loose files copied from old experiments:

- Beta 1: `/Google Drive/Yardman beta/beta.7z.001` through `beta.7z.151`.
- Beta 2: `/Google Drive/Yardman beta/Beta2/beta2.7z.001` through `beta2.7z.232`.

Both Beta 1 and Beta 2 are in scope now. Any older instruction that blocks Beta 2 until Beta 1 is fully exhausted is superseded by this directive. Inventory/recovery may proceed in parallel as long as source identity and dependencies remain auditable.

CarX Fusion is abandoned as a runtime project. Do not put CarX Fusion APK/bootstrap code into Yardman. Unity/CarX/Car Parking/RR3 content may be used only as owner-authorized donor/reference material. Reimplement required behavior in Godot rather than blindly copying engine-specific runtime code.

## Vehicle doctrine: dependency closure or rejection

A filename match or body mesh is never a completed vehicle. Before a vehicle can be called recovered, integrated, game-ready, accepted, or high quality, trace and preserve the complete dependency closure available in the source game:

- canonical identity, source game/version and provenance hashes
- exterior body/chassis geometry and every useful LOD
- interior/cockpit geometry
- wheels, tyres, brakes, hubs and wheel variants
- glass, mirrors, lamps, emissive/light meshes and light textures
- trim, badges, grilles, exhaust, underbody and engine-bay pieces where present
- collision/physics shapes and authored dimensions
- rig, pivots, suspension/wheel anchors, doors/hood/trunk bones or animation pivots
- all materials, shaders/material roles and texture maps
- paint channels, liveries, decals and appearance variants
- body kits, bumpers, skirts, spoilers, hoods, rims and other customization parts
- upgrade/tuning definitions, drivetrain/gearbox/engine/suspension/brake data where recoverable
- audio dependency set: engine layers, turbo/supercharger, exhaust, transmission, tyre/skid, impacts and related events
- UI metadata/icons only after the physical/runtime vehicle is valid
- camera/seat/entry/exit points and player interaction hooks
- source configuration/prefab/entity references required to explain how the original game assembles the car

If a dependency is missing, record it as missing. Do not silently substitute an unrelated host part and call the vehicle complete.

## Fidelity doctrine

Preserve a source-maximum master for every recoverable vehicle. Never permanently destroy detail to meet mobile budgets. Derive runtime LODs, compressed textures and mobile variants from the preserved master. Garage/photo/inspection modes may use higher-detail variants than distance traffic LODs.

The quality target is the complete original-game experience visible in the owner's reference videos: coherent exterior/interior, correct materials, working wheels/lights, customization/upgrade states, tuning, driving, audio, damage/interaction where source-supported, and stable transitions. A mesh that merely renders is not acceptance.

## Mandatory workflow for complex work

For every substantial Yardman task:

1. Maintain a concrete checklist before implementation.
2. Record source files, hashes, dependencies and assumptions.
3. Implement in a narrow lane; do not mix unrelated project files.
4. Validate structurally and in Godot runtime where possible.
5. Criticize the result against the checklist; list failures and uncertainty explicitly.
6. Save expensive decoded/recovered batches immediately to a durable checkpoint.
7. Commit tested scripts/manifests/docs to Git; keep huge/private binary packs in persistent Library/Drive with manifest references.
8. Update `Docs/YARDMAN_CONTINUE.md` so another chat can resume without reconstructing the story from conversation history.

Read these before vehicle work:
- `Docs/YARDMAN_CONTINUE.md`
- `Docs/BETA1_BETA2_SOURCE_AUTHORITY.md`
- `Docs/VEHICLE_MASTER_CHECKLIST.md`
- `Docs/VEHICLE_SELF_CRITIQUE.md`
- `Tools/vehicle_pipeline/README.md`

Do not claim acceptance from extraction, import, a green parser, a headless boot, or one screenshot. Device/gameplay evidence remains the final acceptance gate when behavior cannot be fully validated in CI.
