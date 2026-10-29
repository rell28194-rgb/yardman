# Yardman vehicle master — current execution checklist

Date: 2026-10-29
Canonical branch: `codex/yardman-vehicle-master-20261029`

This is the live complex-task checklist. Update it as gates move; do not replace it with vague progress prose.

## A. Repo/source authority

- [x] Yardman declared default project for bare `continue`.
- [x] CarX Fusion runtime abandoned; donor evidence only.
- [x] Canonical vehicle lane created from live reconciliation branch.
- [x] Live `godot/` source confirmed on canonical branch.
- [x] Beta 1 Google Drive split archive pinned as authoritative source.
- [x] Beta 2 Google Drive split archive pinned as authoritative source.
- [x] PR #4 remains unmerged.
- [x] Old Fleet64 explicitly downgraded to runtime/selector baseline, not high-fidelity acceptance.
- [ ] Reconcile/remove misleading old branch documentation that still claims superseded vehicle authority. Do not delete branches without owner approval.

## B. Process enforcement

- [x] Full dependency-closure acceptance checklist committed.
- [x] Fail-closed vehicle manifest auditor committed.
- [x] Source-max preservation doctrine committed.
- [x] Permanent self-critique/failure-prevention document committed.
- [x] Cross-chat continuation checkpoint committed.
- [x] Source hierarchy flattening auditor committed.
- [x] CarX tuning-profile recovery tool committed.
- [x] CarX customization-table recovery tool committed.
- [x] Car Parking dependency reconciler committed.
- [ ] Add CI fixtures for manifest auditor and source-definition registry.
- [ ] Add Godot headless regression coverage for source vehicle definition loading and per-vehicle dynamics switching.

## C. CarX source fleet recovery

- [x] Original CarX PlayerCars catalog recovered.
- [x] 92 source tuning-profile families discovered.
- [x] 83 complete Stock/Turbo/Drift/Racing/Ultimate five-stage families identified.
- [x] 87 profile families matched to PlayerCar prefabs.
- [x] Source customization databases verified: paint/glass/smoke/rims/spokes/tyres/wheel caps/profiles.
- [x] Supra source PlayerCar record recovered.
- [x] Supra five full source physics/upgrade XML profiles recovered.
- [x] Supra source tuning-controller breadth recovered (17 Racing/Drift, 30 Ultimate controls).
- [x] Supra source customization option counts recovered.
- [x] Supra stock wheel prefab member identified.
- [x] Existing flattened Supra hero GLB proven insufficient: 56/69 source GameObjects lose exact hierarchy identity.
- [ ] Generate durable fleet index for all 92 CarX profile families with source catalog/default customization IDs.
- [ ] Resolve CarX wheel prefab geometry/material PPtr closure in bulk.
- [ ] Resolve tyre prefab closure in bulk.
- [ ] Recover CarX vehicle-specific audio/bank/event relationships.
- [ ] Build and validate CarX source-physics → Yardman dynamics mapper; preserve raw source profiles even after mapping.
- [ ] Reconstruct Supra source-max Godot hierarchy from raw source, not the flattened hero GLB.
- [ ] Make source paint/glass/lights/rims/tyres functional in the Supra inspection scene.
- [ ] Implement source upgrade/profile selection with real runtime physics changes.
- [ ] Run visual/driving/customization/lifecycle/device gates before promoting Supra.

## D. Car Parking source fleet recovery

- [x] Preserved production checkpoint reopened instead of trusting stale migration summary.
- [x] 237 per-car Addressables bundle records confirmed.
- [x] 230 identities resolved directly from decoded catalog.
- [x] 6 additional identity hints recovered from source model-directory evidence.
- [x] Only car122 remains fully unidentified in this checkpoint.
- [x] Per-car dependency frontier quantified: 236 car/body/LOD/engine-sound prefabs; 147 body-kit configs; 137 animation families; 136 front-bumper families; 124 rear-bumper; 127 skirts; 110 hoods; 87 fenders.
- [x] Car 49 Toyota Supra 1998 proven to have body-kit + animation + engine-sound dependency graph.
- [x] Car 218 Toyota Crown 2013 source dependency frontier retained as separate high-detail recovery lane.
- [ ] Generate durable 237-car dependency index from preserved container records.
- [ ] Resolve external/shared Addressables dependencies for each car bundle.
- [ ] Decode body-kit config assets and compatibility rules.
- [ ] Decode all referenced body-part prefabs for one reference vehicle end-to-end.
- [ ] Decode engine-sound prefab dependency graph and source audio clips/events.
- [ ] Decode entry/exit/door/hood/trunk animation semantics.
- [ ] Recover shared rim/tyre libraries and per-car fitment rules.
- [ ] Recover source physics/upgrade/tuning configuration for Car Parking vehicles.
- [ ] Promote one source-complete Car Parking reference car through the full Yardman checklist.
- [ ] Batch the proven pipeline across all recoverable Car Parking cars.

## E. RR3 source fleet recovery

- [x] Seven complete recovered RR3 file families preserved in manifest evidence.
- [x] 2014 Audi R8 Spyder family has exterior a–h, shared, interior a/b, points, dashplanes, animation, wing animation, wheel/light textures and seven liveries.
- [ ] Recover/reconstruct the exact RR3 binary source checkpoint for these seven families from Beta 2 where needed.
- [ ] Decode wheel/brake/tyre geometry semantics.
- [ ] Decode M3G material/shader binding comprehensively.
- [ ] Recover source physics/performance/tuning data.
- [ ] Recover source audio relationships.
- [ ] Recover equipment/customization rules.
- [ ] Build source-max RR3 reference vehicle in Godot and validate.

## F. Godot runtime architecture

- [x] Source-backed vehicle-definition loader added.
- [x] Source registry added; discovered vehicles stay hidden until runtime-ready.
- [x] Production catalog can expand beyond Fleet64 through source-ready definitions.
- [x] Per-vehicle profile now carries source status, hierarchy, customization, upgrades and dynamics.
- [x] Vehicle controller can load per-vehicle dynamics instead of silently applying one Crown tune to source-backed cars.
- [x] Legacy Fleet64 compatibility behavior is explicitly labeled legacy shared tune.
- [ ] Add source hierarchy runtime builder / dedicated source vehicle scene contract.
- [ ] Add source material translator for paint/glass/lights/interior/tyres/brakes.
- [ ] Add source customization runtime with persistence and compatibility constraints.
- [ ] Add upgrade/profile runtime with actual physics mapping.
- [ ] Add source audio runtime mapping.
- [ ] Add inspection/garage mode capable of source-max LOD/material quality.
- [ ] Add Android LOD/texture derivation without touching source-max masters.
- [ ] Add damage/interaction systems only where source evidence supports them.

## G. Acceptance / evidence

- [x] Static parsing is explicitly not acceptance.
- [x] Owner-visible failure critique required for each vehicle.
- [ ] First source-complete Supra structural gate.
- [ ] First source-complete Supra inspection capture gate.
- [ ] First source-complete Supra driving gate.
- [ ] First source-complete Supra customization/upgrade gate.
- [ ] Android performance gate.
- [ ] Owner/device acceptance gate.
- [ ] After reference pipeline passes, apply batch recovery without weakening the checklist.

## Current highest-value next execution step

Finish the source-complete Toyota Supra reference path far enough to prove the new architecture:
1. recover stock wheel + tyre geometry/material closure from original CarX source;
2. preserve the full 69-GameObject hierarchy descriptor;
3. map source material semantics into a dedicated Godot vehicle scene;
4. implement source customization selections and five source upgrade profiles as real runtime state;
5. validate before using the pipeline for the other 82 complete CarX profile families.

In parallel, generate the 237-car Car Parking dependency index because its preserved body-kit/animation/audio structure is substantially richer than the old Fleet64 lane and should become the primary source for highly customizable vehicles.
