# Car Parking Multiplayer — fleet reconciliation baseline

Date: 2026-10-29
Source evidence: `Yardman-Vehicle-Production-002-Checkpoint.zip`
Source game: Car Parking Multiplayer 4.9.11 recovery lane

## Correction to the old migration manifest

The earlier full-fleet migration manifest described almost all Car Parking `car<N>` bundles as anonymous / `pending_catalog_decode`. That description is stale.

The preserved production checkpoint already contains:
- `catalog_containers.json`: **237** recovered per-car Addressables bundle records
- `catalog_model_directory_ids.json`: a decoded source catalog mapping model-directory IDs to vehicle names
- `fleet_identity_index.json`: the larger source identity workspace
- eight deep candidate dependency inspections

Running the new dependency reconciler against the preserved data yields:
- recovered car bundles: **237**
- identity resolved directly from decoded catalog: **230**
- identity supported by model-directory hints only: **6**
- fully unresolved identity in this checkpoint: **1** (`car122`)

Tool: `Tools/vehicle_pipeline/reconcile_car_parking_dependencies.py`.

## Dependency evidence coverage across the 237 bundles

The original Unity container paths prove that the bundles carry substantially more than hero body meshes:

| Dependency category | Cars with evidence |
|---|---:|
| car prefab | 236 |
| body prefab | 236 |
| LOD prefab | 236 |
| engine-sound prefab | 236 |
| body-kit config asset(s) | 147 |
| vehicle animations | 137 |
| front-bumper variants | 136 |
| skirt variants | 127 |
| rear-bumper variants | 124 |
| hood variants | 110 |
| fender variants | 87 |
| explicit interior prefab | 31 |
| source material paths in per-car bundle | 173 |

The lack of an explicit path in a per-car bundle is not proof a dependency does not exist; shared Addressables bundles may provide materials, rims, tyres, spoilers, textures or audio. This table is a lower bound from the per-car container records only.

## Six identity-hint-only bundles

These still require catalog reconciliation before `RECOVERED` status:
- `car101`: source paths reuse model directory `37 Ford Transit SuperSportVan`; likely a distinct derivative/utility configuration, not safe to relabel automatically.
- `car161`: bundle contains source directory `161Jeep14` plus several shared material references.
- `car173`: source directory `173Cls2012`.
- `car182`: source directory `180_182 Ford F150` with animation 182.
- `car251`: shared directory `251-255 Altezza_Lexus` with dedicated 251 animation/body-kit/prefab paths.
- `car255`: shared directory `251-255 Altezza_Lexus` with dedicated 255 animation/body-kit/prefab paths.

Fully unresolved from this checkpoint:
- `car122`: only the sell-model prefab path is present in the per-car container record. Do not guess its identity.

## Examples that show why body-only imports are unacceptable

### Car 49 — Toyota Supra 1998

Decoded catalog identity: `toyota supra 1998`.
Per-car source container includes:
- car prefab
- body prefab
- LOD prefab
- body-kit config assets
- **5** front-bumper prefabs
- **4** rear-bumper prefabs
- **4** skirt prefabs
- **4** hood prefabs
- **4** fender prefabs
- engine-sound prefab
- **10** vehicle animation clips
- source material paths

This is the correct dependency starting point for a high-fidelity Yardman Supra from Car Parking. A single GLB cannot represent this source vehicle.

### Car 218 — Toyota Crown 2013

Decoded catalog identity: `toyota crown 2013`.
Per-car source container includes:
- car prefab
- body prefab
- LOD prefab
- body-kit config assets
- **2** front-bumper prefabs
- engine-sound prefab
- **20** vehicle animation clips

Separate Crown recovery already proved the prefab has a larger source geometry/material/LOD dependency set and a missing stock rim dependency. The source must be rebuilt from those dependencies, not from the old generated Yardman wheel/body substitute.

### Car 0 — BMW E36 M3

Per-car source container includes:
- car/body/LOD prefabs
- body-kit configs
- **7** front bumpers
- **7** rear bumpers
- **6** skirts
- **4** hoods
- **4** fenders
- engine-sound prefab
- **10** animations

### Cars 251 / 255 — Altezza/Lexus shared family

Each dedicated car bundle carries:
- car/body/LOD prefabs
- body-kit configs
- **11** front bumpers
- **6** rear bumpers
- **6** skirts
- **6** hoods
- engine-sound prefab
- **18** animations

These two share a source model directory but have distinct animation/body/prefab IDs. They must not be collapsed into one car without proving equivalence.

## Source catalog breadth

The decoded model-directory index contains source names for a broad fleet spanning sedans, sports cars, supercars, trucks, buses, classics and recent vehicles. Examples include BMW E36/M4/M5/M8, multiple Audi R8/RS families, GT-R R34/R35, Supra 1998/Supra 2020/Supra MK3 A70, Evo IX/X, RX-7/RX-8, Civic, S2000, Corvettes, Viper, Aventador, Chiron, Jesko, F40, McLaren/Pagani, trucks/buses and many more.

The catalog name is identity evidence, not completion evidence. Each car still requires a per-vehicle dependency manifest and actual asset decoding.

## Next required work

1. Generate a durable 237-car source fleet index from the preserved catalog/container data.
2. For every car, treat per-car container paths as the first dependency frontier, then resolve external/shared Addressables dependencies.
3. Recover body-kit configs and every referenced part prefab rather than only the base body.
4. Recover engine-sound prefab dependency closure and source audio clips/events.
5. Recover animation clips and map door/hood/trunk/entry/exit behavior into Godot.
6. Recover shared rims/tyres/materials/textures and preserve source part compatibility rules.
7. Promote a car from `DISCOVERED` only after all required dependency categories are accounted for.

## Self-critique

This reconciliation fixes a major process error: the data was already present in the checkpoint, but the old high-level manifest understated it and later work trusted the stale summary instead of reopening the durable source evidence.

What this proves: source identities and a large part of the per-car dependency frontier exist for almost the whole Car Parking fleet.

What it does not prove: that the referenced prefabs/assets are all decoded, that shared dependencies are complete, or that any of these 237 cars is already Yardman `HIGH-FIDELITY`/`ACCEPTED`.
