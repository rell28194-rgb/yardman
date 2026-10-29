# YARDMAN — MASTER CONTINUATION CHECKPOINT

Date: 2026-10-29
Purpose: cross-chat source of truth for continuing Yardman without re-planning, mixing projects, or falling back to shallow vehicle imports.

---

## 0. NEW-CHAT START PROTOCOL — READ THIS FIRST

If the owner says **`continue`** without naming another project:

1. **Yardman is the default project.** Do not resume CarX Fusion, FC Mobile, PVZ, Lamar, Minecraft, writing projects, or any other prior task unless the owner explicitly names it.
2. Repository: `rell28194-rgb/yardman`.
3. Canonical active branch: `codex/yardman-vehicle-master-20261029`.
4. Fetch the **live branch HEAD** before writing. Never assume a SHA in this checkpoint is still current.
5. Read this file, then `Docs/YARDMAN_CONTINUE.md`, then `Docs/VEHICLE_MASTER_CHECKLIST.md`, then `Docs/VEHICLE_EXECUTION_CHECKLIST_20261029.md`.
6. Inspect the latest relevant workflow result before claiming a gate is green.
7. Do **not** spend the first response retelling project history. Resume the first incomplete execution item and report only useful findings/progress.
8. Do not ask whether to continue. Continue.
9. Never overwrite newer concurrent work. Re-fetch file/blob SHA immediately before GitHub writes.
10. Every complex task must keep a live checklist, evidence log, validation result, self-critique, and durable checkpoint.
11. Never call a vehicle complete because one mesh renders, one GLB exists, a parser succeeds, or CI produces an APK.
12. When the owner asks for an APK or Dropbox file, do not claim delivery until the actual artifact/upload/link is confirmed.

This protocol exists because prior chats repeatedly latched onto the wrong project or resumed from stale branch/file assumptions.

---

## 1. PROJECT IDENTITY

Engine: **Godot 4.7.2**, Compatibility renderer.
Production runtime: `godot/`.
Primary platform: Android.
World target: **full Jamaica at 1:1 metre scale**, all 14 parishes first-class.
Coordinate/world rule: EPSG:3448/JAD2001, no fake vertical compression, streaming/LOD/origin rebasing mandatory.

Do not switch engines.
Do not shrink Jamaica to solve performance.
Do not reduce Yardman to a demo.
Do not replace geographic truth with fake scenery when real recovered/geospatial data exists.

### PR #4 correction

Old handoffs said PR #4 must remain unmerged. That is stale.

Live GitHub confirms PR #4 (`Codex/godot polish 002`) was **merged on 2026-10-16** as merge commit:
`adc558e1e06ba7db77c167097ec90263bcb3199d`

Do not carry the old “PR #4 unmerged” rule forward.

---

## 2. CANONICAL SOURCE / BRANCH AUTHORITY

Canonical vehicle/recovery branch:
`codex/yardman-vehicle-master-20261029`

The branch contains the live `godot/` source tree and is the active lane for source-grade vehicle work.

Observed branch HEAD when this checkpoint was created:
`40f428cb45a69a5fa875653761c2538ad3c7f91e`
message: `vehicles: codify fleet-wide recovery checklist`

This SHA is an observation only. Always fetch live HEAD before work.

Latest observed `World compiler and core` run for that HEAD:
`40828914298` — **success**.

Old branches such as `codex/godot-polish-002`, `codex/accepted-fleet-garage-001`, `codex/world-reconciliation-001`, `codex/vehicle-production-001`, map/reset/fleet branches, and older APK lanes are **reference/history unless explicitly needed for evidence**. Do not assume a branch name means it contains the current Godot source tree.

Repo hygiene rule:
- Git stores source, manifests, converters, tests, small evidence reports, and runtime definitions.
- Large decoded donor/source packs belong in persistent Drive/Library checkpoints.
- Generated Android/runtime derivatives are separate from source-max masters.
- Never mix unrelated project assets into Yardman.

---

## 3. CHAT-HISTORY OWNER DIRECTIVES THAT ARE BINDING

These are not optional style preferences; they are execution rules derived from repeated owner corrections:

- `continue` means **Yardman by default** unless another project is explicitly named.
- Do actual work; do not stall in setup/recovery loops.
- Read the actual current repository/files before changing anything.
- Preserve concurrent work and save progress because chat/workspace resets happen.
- Use checklists for complex work.
- Criticize the work before presenting it as finished.
- Save durable continuation checkpoints so another chat can resume accurately.
- Do not report success from a host-side parse/test when the relevant device/visual/runtime behavior is unproven.
- Do not hide failed or incomplete gates behind “polish remaining.”
- Do not treat filenames as proof of a complete asset dependency set.
- Do not import a body mesh and then fabricate the missing rest of the vehicle from unrelated assets while calling it source-faithful.
- Highest-detail recoverable source quality is the master target; Android optimization must derive lower-cost variants from that master, not destroy the master.
- The final direction is an open-world Yardman build with the real recovered vehicles from the authoritative Beta archives, not a collection of placeholder hero meshes.

---

## 4. AUTHORITATIVE DONOR UNIVERSE

The authoritative donor universe is the two multi-volume archives in connected Google Drive.

### Beta 1
`/Google Drive/Yardman beta/beta.7z.001` through `.151`

### Beta 2
`/Google Drive/Yardman beta/Beta2/beta2.7z.001` through `.232`

Do not treat loose CarX Fusion files, ad-hoc exported GLBs, stale Fleet64 packs, or random checkpoint fragments as source authority when the original Beta archives or verified decoded checkpoints exist.

Source recovery strategy:
1. reconstruct each contained source game/package once;
2. identify/hash it;
3. save object/file/type inventories;
4. build vehicle-family catalogs;
5. resolve each vehicle from root prefab/entity/config through **full dependency closure**;
6. preserve raw source dependency packs with hashes;
7. create neutral source-max masters;
8. derive Godot/Android runtime variants from those masters;
9. keep evidence so later chats do not need to re-decompress 151/232 volumes repeatedly.

---

## 5. WHAT “COMPLETE VEHICLE” MEANS

A vehicle is not complete unless the recoverable source closure has been investigated and the relevant pieces are either integrated or explicitly documented as unavailable.

Required categories:
- exterior body geometry;
- interior geometry;
- all useful source LODs;
- wheel roots/hubs;
- rims;
- tyres;
- brake discs/calipers;
- suspension/alignment semantics when recoverable;
- glass;
- lights and emissive states;
- materials/shaders;
- textures;
- source scale/dimensions;
- collision;
- camera points;
- seat/entry/exit points;
- exhaust/pop points;
- inspection/garage presentation hooks;
- source vehicle configuration;
- tuning/upgrades with actual runtime effects;
- customization/body kits/paint/liveries/rims where present;
- vehicle-specific audio and source event relationships;
- animations;
- UI/config metadata needed to reproduce source behavior;
- source evidence/provenance;
- stable Godot runtime and Android behavior.

Status must fail closed. A partially recovered car must stay `DISCOVERED`/`RECOVERED`/equivalent and remain out of the production garage until its runtime-ready gates pass.

---

## 6. WHY THE OLD VEHICLE PIPELINE WAS REJECTED

The owner rejected the old approach because it proved too shallow.

### Fleet64 limitation

The old Fleet64 result proved useful **runtime/selector infrastructure**, not 64 source-faithful vehicles.

A valid GLB + name + garage slot does not prove:
- complete geometry;
- wheel/brake/interior closure;
- customization;
- upgrades;
- physics identity;
- source audio;
- inspection quality.

### Hard-coded shared physics defect

The live runtime previously swapped visual GLBs while the controller kept a single hard-coded Crown-oriented performance model underneath every car. That meant visually different cars could still drive as the same vehicle.

The source-backed vehicle architecture now allows per-vehicle dynamics definitions. Legacy Fleet64 shared dynamics remain compatibility behavior only until each vehicle is reconciled.

### Flattened hierarchy defect

Toyota Supra source evidence contained **69 GameObjects**. The old hero GLB preserved only **13 exact source object names**, meaning **56 source objects were flattened/dropped as identities**.

Those omitted source objects include important runtime semantics such as wheel roots, calipers, camera points, collision hierarchy, exhaust/engine hooks, interior/body LOD-related nodes, and other authored markers.

Therefore the new pipeline reconstructs/preserves source hierarchy instead of treating the flattened hero GLB as the master.

### CarX Fusion lesson

The abandoned CarX Fusion experiment repeatedly showed why mesh-only/member-only patching is insufficient. Vehicles that looked present in an archive were unusable when catalog, materials, dependencies, configuration, or runtime relationships were incomplete.

CarX Fusion is abandoned unless the owner explicitly reopens it. Its files/runtime must not contaminate Yardman.

---

## 7. OWNER VEHICLE ACCEPTANCE / REJECTION HISTORY

Important historical acceptance facts:

- **Crown007 / Toyota Crown** was the visually accepted vehicle baseline in Yardman.
- Crown should not be interpreted as the only vehicle or as a universal physics donor for every car.
- **Marx** was not accepted.
- **992 / Port Royal 992** was not accepted and remains excluded/scrapped in prior fleet policy.
- Toyota Mark X was excluded/scrapped in prior fleet policy.
- Corvette C7 and DeLorean were previously held when dedicated hero media was missing; do not silently substitute another model.

These old states remain evidence, but new Beta1/Beta2 source-grade recoveries can supersede old placeholder/held status only after the new acceptance checklist passes.

---

## 8. CURRENT SOURCE RECOVERY STATE

### 8.1 CarX Drift 1.16.2 source lane

The old hero-GLB lane is superseded by catalog/profile/dependency recovery.

Confirmed source recovery:
- 92 tuning-profile families;
- 83 families with Stock / Turbo / Drift / Racing / Ultimate stages;
- 87 profile families matched to PlayerCar catalog prefabs;
- customization tables recovered/verified for PlayerCars, Profiles, CarProfileParameters, WheelTires, CarColors, GlassColors, SmokeColors, WheelCapDictionaryXML, WheelRimColorsDictionaryXML, WheelSpokeColorsDictionaryXML.

Tools:
- `Tools/vehicle_pipeline/recover_carx_vehicle_profiles.py`
- `Tools/vehicle_pipeline/recover_carx_customization.py`
- `Tools/vehicle_pipeline/build_hierarchy_descriptor.py`

### Toyota Supra RZ — current reference family

Source identity:
- PlayerCar ID 10;
- prefab `ToyotaSupraRZ`;
- identifier `supraRZ`.

Recovered evidence includes:
- original 69-GameObject hierarchy;
- old LOD0 GLB flattened/dropped 56 exact source identities;
- source default paint/wheel/rim/spoke/tyre/smoke/glass IDs;
- 46 wheel/rim choices;
- 5 tyre choices with source grip multipliers;
- 13 paint colors;
- 13 glass colors;
- 13 smoke colors;
- 16 rim colors;
- 16 spoke colors;
- five source physics/upgrade profiles grounded in `godot/data/vehicles/toyota_supra_rz/vehicle.json`;
- Racing/Drift expose 17 tuning controls;
- Ultimate exposes 30 tuning controls;
- stock wheel prefab source member identified as `8368d937e9b203d499bffc164cf9f6f8`.

Supra is **NOT runtime-ready** yet.

Outstanding Supra gates:
1. finish source wheel + tyre dependency closure;
2. reconstruct/preserve full hierarchy in a dedicated Godot scene;
3. translate source materials, paint, glass, lights, wheel materials;
4. bind real customization selections and persistence;
5. validate CarX source physics → Yardman dynamics mapping for all five profiles and tuning controls;
6. recover vehicle-specific source audio/event relationships;
7. map collision, camera, entry/exit, seat and exhaust hooks;
8. inspection/garage presentation acceptance;
9. Android performance/LOD derivative validation;
10. only then promote runtime-ready/accepted.

Evidence files:
- `Docs/vehicle_evidence/ToyotaSupraRZ-hierarchy-audit-20261029.md`
- `Docs/vehicle_evidence/ToyotaSupraRZ-customization-audit-20261029.md`

### 8.2 Car Parking Multiplayer source lane

Recovered production evidence proves the old “anonymous bundles” summary was stale.

Known recovery:
- 237 recovered per-car Addressables bundle records;
- 230 identities directly resolved from catalog;
- 6 additional model-directory identity hints;
- only car122 remained fully unresolved in that checkpoint;
- 236 car prefabs;
- 236 body prefabs;
- 236 LOD prefabs;
- 236 engine-sound prefabs;
- 147 body-kit config families;
- 137 animation families;
- 136 front-bumper families;
- 124 rear-bumper families;
- 127 skirt families;
- 110 hood families;
- 87 fender families.

Tool:
`Tools/vehicle_pipeline/reconcile_car_parking_dependencies.py`

Reference examples:
- car49 Toyota Supra 1998: 5 front bumpers, 4 rear bumpers, 4 skirts, 4 hoods, 4 fenders, engine-sound prefab, LOD/body/car prefabs, 10 animations.
- car218 Toyota Crown 2013: car/body/LOD prefabs, body-kit configs, 2 front bumpers, engine-sound prefab, 20 animations; separate Crown recovery contains deeper geometry/material/LOD evidence.

Evidence:
`Docs/vehicle_evidence/CAR_PARKING_FLEET_RECONCILIATION_20261029.md`

### 8.3 Real Racing 3 source lane

Seven durable recovered source families:
- `2012_audi_r8_lms`
- `2014_audi_r8spyder`
- `2017_bmw_m4_dtm`
- `2017_mercedes_c63_dtm`
- `2018_audi_r8_gt4`
- `2018_bmw_m4_gt4`
- `2021_bmw_m4_gt3`

R8 Spyder evidence includes exterior a-h, shared, interior a/b, points, dashplanes, animation, wing animation, wheel/light textures, and seven liveries.

RR3 families remain incomplete until wheel/brake/physics/audio/customization closure is proven.

---

## 9. CURRENT GODOT VEHICLE ARCHITECTURE

The canonical branch now contains the source-backed vehicle architecture.

Important files:
- `godot/scripts/vehicle_definition.gd`
- `godot/scripts/vehicle_catalog.gd`
- `godot/scripts/fleet_vehicle_model.gd`
- `godot/scripts/vehicle_controller.gd`
- `godot/scripts/vehicle_selector_runtime.gd`
- `godot/data/vehicles/index.json`
- per-vehicle `godot/data/vehicles/<id>/vehicle.json`

Current design intent:
- source-backed definitions carry status, source evidence, hierarchy descriptor, primary/inspection scenes, dynamics, customization and upgrades;
- only runtime-ready source definitions expand the production catalog;
- incomplete source vehicles remain hidden;
- legacy Fleet64 remains available as compatibility infrastructure;
- source-backed vehicles can own their dynamics instead of silently using the Crown tune;
- source hierarchy is intended to survive into Godot rather than being flattened into a generic shell/wheel template.

No new source vehicle should be called accepted merely because this architecture exists.

---

## 10. WORLD / ANDROID HISTORY THAT MUST NOT BE FORGOTTEN

Yardman is not only a vehicle project. Vehicle work must preserve the accepted open-world runtime.

Historical validated/reconciliation lineage included:
- full Jamaica world restoration;
- tiled streaming/LOD;
- terrain/coast/building/road runtime work;
- garage switching/touch browsing;
- Fleet64 packaging checks;
- Android export/signature validation.

There were also repeated failures in geometry-safety/Godot gates during reconciliation. Do not cite a historical green run as proof the current head is green.

Host CI APK validation is **not** equivalent to:
- real `adb install`;
- launch on the owner's Android device;
- sustained streaming/performance/thermal behavior;
- touch interaction;
- owner visual acceptance;
- private-source vehicle quality.

Physical/device acceptance must remain a separate gate.

### Garage/download interaction requirement from chat history

The garage must remain usable on touch devices as well as hardware controls.

The owner previously required:
- touch-accessible GARAGE controls, not only keyboard `G`;
- prominent vehicle-download progress;
- visible bytes / percent / status rather than a hidden or ambiguous downloader state.

Do not regress those UX requirements while rebuilding vehicles.

---

## 11. SELF-CRITIQUE / KNOWN FAILURE MODES

Before presenting a vehicle/system as finished, explicitly test for these prior failure patterns:

1. **Filename tunnel vision** — found one file named after the car and stopped searching.
2. **Mesh-only recovery** — body present; interior/wheels/materials/config absent.
3. **Flattened hierarchy** — source semantic nodes destroyed by GLB conversion.
4. **Cross-model substitution** — missing parts silently borrowed from another vehicle.
5. **Shared fake dynamics** — all cars visually differ but use one tune.
6. **Customization illusion** — options listed but not backed by real source assets/runtime effects.
7. **Upgrade illusion** — stage/profile names exist but physics does not change.
8. **Audio omission** — engine/exhaust/turbo/transmission/surface relationships not resolved.
9. **Inspection mismatch** — driving mesh works but garage/inspection view exposes broken materials/parts.
10. **CI overclaim** — parser, CRC, headless, export or signature success presented as device acceptance.
11. **Repo cross-contamination** — files from CarX Fusion or unrelated projects introduced into Yardman.
12. **Stale branch authority** — resumed a branch because its name sounded current.
13. **Checkpoint drift** — old instructions conflict with live GitHub state (example: PR #4 merge status).
14. **Artifact-only success** — generated APK/pack exists but cannot install, launch, stream, or survive normal gameplay.

Every substantial continuation should state which of these failure modes were checked.

---

## 12. EXACT NEXT EXECUTION POINT

When a new chat receives `continue`, the correct immediate lane is:

### Primary lane — Toyota Supra RZ source-complete reference vehicle

Do **not** start by rebuilding the old GLB.

Execute in this order:

1. Fetch live `codex/yardman-vehicle-master-20261029` HEAD and ensure no newer concurrent vehicle work changes the queue.
2. Reopen the Supra source evidence and source-member inventories.
3. Resolve the stock wheel prefab member `8368d937e9b203d499bffc164cf9f6f8` through its full mesh/material/texture dependency graph.
4. Resolve all 5 source tyre definitions to the actual tyre/wheel assets and grip data.
5. Produce/update a machine-readable Supra dependency-closure manifest with status per dependency category.
6. Generate the dedicated Godot hierarchy descriptor/scene preserving all recoverable source nodes, transforms and semantic hooks.
7. Map wheels/calipers/collision/cameras/seat/exhaust/light nodes into explicit Godot roles.
8. Translate source material semantics before styling anything manually.
9. Bind source customization choices only when the corresponding recovered assets exist.
10. Implement/validate source physics profile mapping for Stock/Turbo/Drift/Racing/Ultimate.
11. Recover source audio relationships.
12. Run structural + Godot parse/runtime + visual/inspection + driving + lifecycle tests.
13. Self-critique against Section 11.
14. Only then promote Supra from `DISCOVERED` toward `GAME-READY`.

### Parallel inventory lane

Without blocking Supra reference integration:
- continue fleet-wide Beta1/Beta2 vehicle inventory;
- preserve Car Parking 237-car dependency map;
- retain RR3 seven-family source evidence;
- classify legacy Fleet64 vehicles as placeholder/partial/source-complete rather than assuming quality from availability.

---

## 13. DEFINITION OF SUCCESS FOR THE NEXT MAJOR MILESTONE

The next milestone is **not** “more cars appear in the garage.”

It is:

> One reference vehicle (Toyota Supra RZ) exists in Yardman as a source-grounded, inspectable, driveable, customizable, upgradeable, hierarchy-preserving vehicle whose recovered parts/configuration/dynamics/audio are documented and validated end-to-end, while the full Jamaica runtime remains intact.

After that pipeline is proven, generalize it across every recoverable Beta1/Beta2 vehicle without weakening the gates.

---

## 14. FINAL CONTINUATION RULE

If there is any contradiction between:
- an old chat summary,
- an old handoff,
- a branch name,
- a stale checkpoint,
- and the live repository / live source evidence,

**inspect the live repository/source first and update this checkpoint with the corrected fact.**

Do not guess. Do not silently carry stale instructions forward.
