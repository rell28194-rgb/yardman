# YARDMAN — canonical continuation checkpoint

Updated: 2026-10-29

## Default continuation rule

Yardman is the active/default project. If the owner says `continue` without naming another project, resume Yardman from this checkpoint and inspect the live repository state before writing.

Do not resume CarX Fusion. That experiment is abandoned unless the owner explicitly reopens it.

## Repository and canonical lane

Repository: `rell28194-rgb/yardman`
Canonical vehicle/recovery branch: `codex/yardman-vehicle-master-20261029`
Created from live `codex/world-reconciliation-001` head observed as `a6e36d021034293d8b1bbe9a012c38cce443a477` on 2026-10-29.

That historical SHA is a creation anchor, not a permanent HEAD. Always fetch the live canonical branch before changes.

Engine: Godot 4.7.2 Compatibility renderer.
Target: Android-first open world.
World: full Jamaica, 1:1 metre scale, all 14 parishes, EPSG:3448, streaming/LOD/origin rebasing.
PR #4 remains unmerged unless explicitly ordered.

The canonical branch contains the live `godot/` source tree. Do not build new vehicle systems against artifact-only legacy branches.

## Last validated game checkpoint inherited by this lane

The saved reconciliation handoff identifies the validated Yardman Android lineage on `codex/world-reconciliation-001`, including:
- accepted Jamaica world restoration
- Fleet64 packaging/runtime checks
- garage switching and touch browsing
- Crown reference-model handling
- Android export/signing validation

Do not reinterpret Fleet64 as high-fidelity acceptance. It is a useful runtime/selector baseline only.

## Owner directive — vehicle target

Recover and integrate every useful vehicle from the authoritative Beta 1 and Beta 2 Google Drive archives into Yardman at the highest source fidelity reasonably recoverable.

Authoritative archives:
- Beta 1: `/Google Drive/Yardman beta/beta.7z.001` through `.151`
- Beta 2: `/Google Drive/Yardman beta/Beta2/beta2.7z.001` through `.232`

The vehicle target is not a body mesh. Each vehicle must preserve or recreate the complete recoverable experience:
- exterior + interior + all useful LODs
- materials/textures/glass/lights
- wheels/tyres/brakes/suspension alignment
- collision and authored dimensions
- customization/body kits/paint/liveries/rims where source-backed
- upgrade/tuning data and actual runtime effects
- source audio/event relationships
- camera/seat/entry/exit/garage inspection hooks
- source-specific configuration and assembly evidence
- stable Godot driving and Android scaling

Read `Docs/VEHICLE_MASTER_CHECKLIST.md` and `Docs/VEHICLE_EXECUTION_CHECKLIST_20261029.md` before promoting status.

## Current source recovery state

### CarX Drift 1.16.2 lane

The old hero-GLB lane is superseded by source catalog/profile recovery.

Confirmed from the original source:
- 92 tuning-profile families
- 83 families with all five source stages: Stock / Turbo / Drift / Racing / Ultimate
- 87 profile families match a PlayerCar catalog prefab
- source customization tables verified: PlayerCars, Profiles, CarProfileParameters, WheelTires, CarColors, GlassColors, SmokeColors, WheelCapDictionaryXML, WheelRimColorsDictionaryXML, WheelSpokeColorsDictionaryXML

Tools:
- `Tools/vehicle_pipeline/recover_carx_vehicle_profiles.py`
- `Tools/vehicle_pipeline/recover_carx_customization.py`
- `Tools/vehicle_pipeline/build_hierarchy_descriptor.py`

Toyota Supra RZ is the first reference family:
- CarX PlayerCar ID 10 / prefab `ToyotaSupraRZ` / identifier `supraRZ`
- original 69-GameObject hierarchy retained in source evidence
- legacy LOD0 GLB flattened/dropped exact identity for 56 of those GameObjects
- source default paint/wheel/rim/spoke/tyre/smoke/glass IDs recovered
- 46 wheel/rim choices
- 5 tyres with source grip multipliers
- 13 paint, 13 glass, 13 smoke, 16 rim-color and 16 spoke-color choices
- five real source physics/upgrade profiles recovered and grounded in `godot/data/vehicles/toyota_supra_rz/vehicle.json`
- Racing/Drift expose 17 tuning controls; Ultimate exposes 30
- stock wheel prefab source member identified as `8368d937e9b203d499bffc164cf9f6f8`

Supra remains `DISCOVERED`, not runtime-ready. Missing gates include wheel/tyre dependency closure, source hierarchy reconstruction in Godot, material translation, source audio, collision mapping and validated physics translation.

Evidence:
- `Docs/vehicle_evidence/ToyotaSupraRZ-hierarchy-audit-20261029.md`
- `Docs/vehicle_evidence/ToyotaSupraRZ-customization-audit-20261029.md`

### Car Parking Multiplayer lane

The old migration statement that nearly all bundles were anonymous is stale.

Reopened preserved production evidence proves:
- 237 recovered per-car Addressables bundle records
- 230 identities directly resolved from decoded catalog
- 6 additional model-directory identity hints
- only car122 fully unresolved in this checkpoint
- 236 car prefabs
- 236 body prefabs
- 236 LOD prefabs
- 236 engine-sound prefabs
- 147 body-kit config families
- 137 animation families
- 136 front-bumper families
- 124 rear-bumper families
- 127 skirt families
- 110 hood families
- 87 fender families

Tool:
- `Tools/vehicle_pipeline/reconcile_car_parking_dependencies.py`

Important reference examples:
- car49 Toyota Supra 1998: 5 front bumpers, 4 rear bumpers, 4 skirts, 4 hoods, 4 fenders, engine-sound prefab, LOD/body/car prefabs and 10 animations.
- car218 Toyota Crown 2013: car/body/LOD prefabs, body-kit configs, 2 front bumpers, engine-sound prefab and 20 animations; separate Crown recovery retains deeper geometry/material/LOD evidence.

Evidence:
- `Docs/vehicle_evidence/CAR_PARKING_FLEET_RECONCILIATION_20261029.md`

### Real Racing 3 lane

Seven source families remain recovered in durable manifest evidence with per-file hashes:
- 2012_audi_r8_lms
- 2014_audi_r8spyder
- 2017_bmw_m4_dtm
- 2017_mercedes_c63_dtm
- 2018_audi_r8_gt4
- 2018_bmw_m4_gt4
- 2021_bmw_m4_gt3

The R8 Spyder family includes exterior a–h, shared, interior a/b, points, dashplanes, animation, wing animation, wheel/light textures and seven liveries. It remains `DISCOVERED` because physics/audio/customization/wheel/brake closure is incomplete.

## Current Godot runtime changes

Source-backed vehicle architecture now exists in the live Godot source:
- `godot/scripts/vehicle_definition.gd`
- `godot/data/vehicles/index.json`
- per-vehicle source definitions
- source-ready catalog expansion beyond Fleet64
- source status/customization/upgrades/hierarchy/dynamics carried in profiles
- discovered/incomplete vehicles stay hidden until runtime-ready
- `vehicle_controller.gd` can apply per-vehicle dynamics rather than silently treating every source-backed vehicle as the Crown tune
- legacy Fleet64 shared dynamics remain explicit compatibility behavior until each car is reconciled

No new source vehicle has been promoted to runtime-ready/accepted yet. That is intentional.

## Decomp/recovery strategy

Do not repeatedly re-decompress the whole multi-volume archives for each chat.

Build durable source-game checkpoints:
1. reconstruct each contained game/package once from the split archives
2. hash and identify the exact source package
3. save full object/file/type inventory
4. build vehicle-family index
5. resolve each vehicle from root prefab/entity/config through its dependency graph
6. save raw dependency packs with hashes in persistent Library/Drive
7. save neutral source-max masters separately from mobile/runtime derivatives
8. commit manifest/converter/validator code and small reports to Git

Reopen durable checkpoints before doing expensive recovery again. The 2026-10-29 Car Parking correction demonstrated that stale summaries can hide already-recovered source data.

## Complex-task rule

Every substantial task must have:
- checklist
- source/evidence log
- implementation
- validation
- self-critique
- durable checkpoint

Current live checklist:
`Docs/VEHICLE_EXECUTION_CHECKLIST_20261029.md`

## Immediate execution queue

1. Finish Toyota Supra RZ source wheel + tyre dependency closure from original CarX source.
2. Preserve/reconstruct the full source hierarchy in a dedicated Godot scene rather than using only the flattened hero GLB.
3. Translate source paint/glass/lights/wheel material semantics.
4. Implement source customization selections with real assets and persistence.
5. Build/validate a CarX source-physics → Yardman mapper for the five source upgrade profiles and tuning controllers.
6. Recover vehicle-specific CarX audio relationships.
7. Generate the full 237-car Car Parking dependency index and decode one body-kit-heavy reference vehicle end-to-end.
8. Generalize both proven pipelines across the source fleets without weakening the acceptance checklist.
9. Keep source-max masters permanent; derive Android LOD/texture variants rather than degrading masters.
10. Run owner/device acceptance only after structural, visual, driving, customization and lifecycle gates pass.

## What not to do

- do not identify a vehicle from one filename and stop searching
- do not transplant only a body mesh and call it integrated
- do not use an unrelated host car's missing parts without clearly marking them temporary
- do not flatten customization variants into one baked car
- do not destroy high-detail source geometry to meet mobile budgets
- do not confuse parser/CRC/headless success with visual/gameplay acceptance
- do not mix CarX Fusion runtime code into Yardman
- do not restart the project or switch engines
