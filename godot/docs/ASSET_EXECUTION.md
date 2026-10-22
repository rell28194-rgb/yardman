# Asset execution and completion gates

Updated 2026-10-22 UTC from the owner's execution directive and the current
private recovery checkpoints. The work order remains exhaustive Beta 1 recovery
and validation, Beta 2 independent inventory and quality replacements, then
continued game polishing and terminal packaging. Android CI remains an internal
build-health check throughout.

## Current verified scope

The complete Beta 1 outer header contains 42 entries and 40 independent streams,
in 151 volumes totalling 3,793,615,057 bytes. Its libraries include Gangstar 4,
Car Mechanic 21, CarX Drift, CarX Highway and a GTA 5 map archive. An empty
Gangstar split-file entry is recorded separately. The nested CarX split archive
has been compared: its decoded APK matches the direct APK byte count and SHA-256,
so the redundant copy is deliberately rejected. The full CarX APK/OBB static
inventory now covers 247,863 objects across 72 serialized types, with zero
parse, metadata or hash errors. Its eighteen-category family classification
and useful-family recovery remain open. The old model-only catalog cannot
certify Beta 1 completion.
`asset_recovery/beta1_archive_index.json` records every outer member without
committing any reference-game media. Inner inventories and useful-family
recovery remain open. Mechanic now has a complete static pass: all 2,725 APK
members verified and 95,834 objects across 81 types enumerated. Its family
classification/integration remains open. The four-member GTA map archive was
fully inspected and rejected for runtime substitution: a combined fictional
relief and UV-specific baked imagery cannot replace registered Jamaica terrain
or independent road/building kits.

Beta 2 is no longer an unopened library. The owner-private outer inventory now
covers 232 parts, 488 outer entries and 12,126,506,954 logical bytes across
sources including RR3, Tropico, Car Parking Multiplayer, SimCity, uCaptain and
ARK. This establishes outer-container coverage, not exhaustive useful-family
acceptance. Direct uCaptain recovery has produced a mountain-terrain albedo,
scrub-grass albedo and normal, and WaterBump normal in the private reference
pack. The reconciliation runtime now treats those as optional quality inputs:
mountain/scrub albedos can replace semantic terrain textures, scrub normal adds
near-field micro relief, and WaterBump adds ocean micro-normal detail. Registered
DEM, coastline, sea level, road geometry and hydrology remain authoritative;
none of these source textures grants geographic or terrain-mutation authority.
Missing private media always falls back to the public/procedural path.

The private pack currently contains recovered GLBs plus surface media/audio.
That count includes distant LODs and staged props, not an equivalent number of
accepted gameplay systems. The bush is an eight-vertex crossed-card asset
suitable for distant LOD; the same geometry cannot count as a detailed nearby
shrub. Source foliage has a separate red-channel opacity mask which the initial
exporter omitted. The seven-model correction passes imported
alpha/material/bake checks and six actual Compatibility captures. The close-up
green checks isolate their target plant against neutral ground; neighboring
foliage cannot hide a brown crown. `asset_recovery/foliage_batch_001.json`
preserves the exact hashes and scope. That accepts the specific atlas/alpha
regression; close-view photographic leaf cards, broader family recovery and
geographic placement remain open.

The recovered grass brightness translation has a paired actual-render gate:
`terrain_reference_render_test.gd` compares the production shader against the
same source texture under identical runtime lighting. Removing the extra 1.30
gain changes the measured brightness ratio from 1.2927 (expected failure) to
1.0044 (pass). `asset_recovery/ground_batch_001.json` identifies the batch and
capture hashes. The newer Beta 2 scrub/mountain material hooks preserve this
fallback and do not alter registered terrain geometry. Broader
terrain/material/coast acceptance remains open.

The Highway APK full static pass enumerates 162,374 objects across 74 types;
all 1,284 ZIP members were CRC/SHA checked. FMOD banks and 417 samples are
indexed; exhaustive listening and category/family acceptance remain open.
The tested water shader adaptation is recorded in
`asset_recovery/water_batch_001.json`: actual River source channels are
inspected, repetitive highlights reduced, and clipped sea level/UV/rebase
registration preserved. Real before/after national coast captures and a
frozen-clock seam/rebase/source-detail test pass. The private Beta 2 WaterBump
normal is now an optional micro-normal input on top of that registered coast
system. Full water/material and Android performance acceptance remain open.

Three recovered neutral window modules bind to fitting registered external walls
at original metre dimensions. Cell work is bounded to 32 hosts and three shared
MultiMeshes; existing host geometry and collision remain intact.
`asset_recovery/building_facade_batch_001.json` records near collision, rebase,
unload/reload and six actual renders, including unchanged distant fallback.
A previously idle `building_concrete.png` source is also now bound to the
existing deterministic wall-material family at palette alpha 0.6. It shares the
same building material batch and adds no footprint, node, collision or draw
call. These are presentation improvements only; broader architectural quality
and national placement/performance acceptance remain open.

Recovered neutral Beta 1 settlement furniture is now used conservatively in the
near field. `settlement_waste_bin.glb`, `settlement_fire_hydrant.glb` and
`settlement_metal_cabinet.glb` can be placed only from registered road-facing
building frontage, compiled road geometry and registered terrain height. The
runtime is range/density bounded, source metre scale is preserved, and the
props add no collision. Construction cones, portable fences and concrete
barriers remain deliberately withheld: the current road compiler filters
`highway=construction`, so it cannot yet prove work-zone placement. Those assets
must not become random scenery just to increase utilization.

Recovered Beta 1 audio now contributes more source variety without expanding
the established four-voice runtime budget. `engine_drive_loop.wav`,
`gravel_skid_loop.wav`, `grass_roll_loop.wav` and `tire_skid_loop.wav` route
through the existing engine/road players. Compiled paved/unpaved/off-road
surface state selects road timbre, strong paved braking can select the skid
source, and all private-media paths fall back to the existing cached loops when
missing. The headless audio gate verifies the four-voice cap, routing, mix
bounds, loop behavior and cleanup. Listening/device acceptance remains open.

None of these integrations marks Beta 1 or Beta 2 complete. Exhaustive family
classification, provenance decisions, private rendered comparisons, Android
performance/device evidence and further useful-source recovery remain open.

## Evidence ledger

`asset_recovery/ledger.json` records sources, category coverage, family decisions,
regressions and validation references. Do not manually set a completion flag;
`tools/validate_asset_milestone.py` derives completion from those records.

Regression records have a `library` scope, defaulting to `beta1` for older
records. The seven original acceptance areas must stay in Beta 1. A regression
introduced during the later Beta 2 pass blocks Beta 2 acceptance and terminal
packaging without retroactively invalidating an already accepted transition.

For each source, finish the inner container inventory across all object/resource
types, retain source hashes and count every category. Give every category a
classification record, including a cited zero count when it is truly absent.
Every discovered family must occur in both its source classification and the
category's family list. Unreadable formats stay unresolved while another parser
or reference approach is investigated; do not mark them absent.

For each integrated family, retain import, normalization and runtime evidence.
Visible assets also require actual Godot Compatibility render evidence; audio
requires listening evidence; reference systems require analysis and tested
reimplementation evidence. Record bounds/metre scale, orientation, material and
texture/alpha mapping, triangle count/LOD, collision and streaming behavior where
applicable. Evidence must identify its tested asset batch and source revision.
Rejections need a concrete reason and inspection evidence. Duplicate rejections
need a verified content comparison, not a filename match. Beta 2 replacements
also need a quality comparison against the existing asset.

| Coverage category | Required investigation |
| --- | --- |
| Vehicles | Complete vehicle families and usable LODs |
| Vehicle parts | Wheels, bodies, lights, interiors and attachments |
| Road surfaces | Geometry, materials, junctions and driving surfaces |
| Road markings/barriers/signage | Lane paint, curbs, dividers and signs |
| Buildings | Kits, roofs, facades and source hierarchy transforms |
| Storefronts | Shop fronts, entrances and signage |
| Street furniture | Benches, bins, cabinets, hydrants and lighting |
| Vegetation | Atlas opacity, species, branches, grass and LODs |
| Terrain/coastal | Ground detail, rock, sand and geographic placement |
| Water | Water surfaces, foam, caustics and shoreline behavior |
| Props | Other useful environmental/interactive objects |
| Textures/materials | All texture channels, tiling, shaders and translation |
| Characters/animations | Rigs, movement sets and compatible animation data |
| HUD/UI | Layout, touch controls, icons and interaction patterns |
| Audio | Vehicles, surfaces, footsteps, ambience and UI |
| VFX | Particles, lighting effects and compatible behavior |
| Shaders | Source behavior and tested Godot equivalents |
| Reference systems | Controls, driving, cameras, streaming and gameplay formats |

## Batch and transition checks

Run the usual Python, Godot import, headless, rendered and Android checks for
the changed system. Save decoded/private files separately and push only tested
source. Record the exact tests and captures with the batch. Do not pull the next
substantial batch until the current one is imported, normalized and checked;
isolate a regression immediately. Never accumulate an untracked multi-GB media
dump in the public project.

```bash
# Validates ledger structure and reports honest blockers; unfinished work is OK.
python godot/tools/validate_asset_milestone.py
# Beta 2 work already has independent outer/recovery evidence; this command
# still reports whether the formal ledger transition requirements are complete.
python godot/tools/validate_asset_milestone.py --require beta2
# Required only for terminal packaging, after both libraries and polishing.
python godot/tools/validate_asset_milestone.py --require final_packaging
```

CI runs the first command and retains its report. This permits internal APKs
while harvesting remains incomplete. Green public CI validates the asset-absent
fallback and Android pipeline; it does not accept private model quality or prove
phone performance. Final acceptance still needs real rendered game inspection,
playable controls/driving, coast/road correctness and available Android runtime
evidence. A fixture or signed package alone does not establish any of those.

Private checkpoints saved during the exhaustive pass include
`Yardman-Beta1-Exhaustive-Inventory.zip`,
`Yardman-Beta1-Building-Families-Checkpoint.zip`, the Beta 2 outer inventory,
and the canonical personal reference pack. Restore their newest versions from
the project's handoff. Keep this ledger synchronized with each stable batch;
document pending work before any session ends.
