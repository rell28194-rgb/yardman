# YARDMAN — canonical continuation checkpoint

Date established: 2026-10-29

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

## Last validated game checkpoint inherited by this lane

The saved reconciliation handoff identifies the validated Yardman Android lineage on `codex/world-reconciliation-001`, including:
- accepted Jamaica world restoration
- authoritative Fleet64 recovery/packaging checks
- 64 dedicated vehicle runtime packaging
- garage switching and touch browsing
- Crown reference-model handling
- Android export/signing validation

Do not reinterpret that as high-fidelity acceptance for every Fleet64 vehicle. The owner has explicitly rejected that quality bar for the donor fleet. Fleet64 is a useful runtime/selector baseline only.

## New owner directive — vehicle target

Recover and integrate every useful vehicle from the authoritative Beta 1 and Beta 2 Google Drive archives into Yardman at the highest source fidelity reasonably recoverable.

Authoritative archives:
- Beta 1: `/Google Drive/Yardman beta/beta.7z.001` through `.151`
- Beta 2: `/Google Drive/Yardman beta/Beta2/beta2.7z.001` through `.232`

Do not use loose CarX Fusion files as source authority.

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

Read `Docs/VEHICLE_MASTER_CHECKLIST.md` before calling any vehicle game-ready or accepted.

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
8. commit the manifest/converter/validator code and small reports to Git

Existing durable Beta 1 inventories/recovery packs should be reused when their identities match.

## Complex-task rule

Every substantial task must have:
- checklist
- source/evidence log
- implementation
- validation
- self-critique
- durable checkpoint

Update this file when the canonical branch, source authority, accepted vehicle baseline or next execution gate changes.

## Immediate execution queue

1. Build the machine-readable vehicle dependency manifest/schema and validator.
2. Reconcile the existing Fleet64 catalog against authoritative Beta1/Beta2 identities; classify each as placeholder, partial recovery, or complete source family.
3. Build a persistent source-game/vehicle index from the existing exhaustive inventories before downloading duplicate data.
4. Select one source-complete vehicle as the reference pipeline target. Prefer a family with known complete recovery, but do not stop fleet inventory work while that reference is integrated.
5. For the reference vehicle, recover the full dependency closure and source-max neutral master before Godot import.
6. Build Godot systems for full-quality materials, glass/lights, interior, wheel/brake hierarchy, customization/upgrade state, source-derived tuning/audio and inspection.
7. Generalize the pipeline and batch through every recoverable Beta1/Beta2 vehicle.
8. Keep source-max masters permanent; derive Android LOD/texture variants rather than degrading masters.
9. Run owner/device acceptance only after the specific vehicle passes structural, visual, driving, customization and lifecycle gates.

## What not to do

- do not identify a vehicle from one filename and stop searching
- do not transplant only a body mesh and call it integrated
- do not use an unrelated host car's missing parts without clearly marking them temporary
- do not flatten customization variants into one baked car
- do not destroy high-detail source geometry to meet mobile budgets
- do not confuse parser/CRC/headless success with visual/gameplay acceptance
- do not mix CarX Fusion runtime code into Yardman
- do not restart the project or switch engines
