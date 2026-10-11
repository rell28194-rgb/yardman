# Asset execution and completion gates

Updated 2026-10-11 UTC from the owner's execution directive. The work order is
Beta 1 exhaustive recovery and validation, then Beta 2 independent inventory
and quality replacements, then continued game polishing and terminal packaging.
Android CI remains an internal build-health check throughout.

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
recovery remain open. Beta 2 contents have not been inspected.

The private pack currently has 13 decoded GLBs plus surface media/audio. That
count includes distant LODs and staged props, not 13 accepted gameplay systems.
The bush is an eight-vertex crossed-card asset suitable for distant LOD; the
same geometry cannot count as a detailed nearby shrub. Source foliage has a
separate red-channel opacity mask which the initial exporter omitted. The
seven-model correction now passes imported alpha/material/bake checks and six
actual Compatibility captures. The close-up green checks isolate their target
plant against neutral ground; neighboring foliage cannot hide a brown crown.
`asset_recovery/foliage_batch_001.json` preserves the exact hashes and scope.
That accepts the specific atlas/alpha regression; close-view photographic
leaf cards, broader family recovery and geographic placement remain open.

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
# Required before opening Beta 2 contents; exits nonzero while Beta 1 is open.
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

Private checkpoints saved during the exhaustive pass:
`Yardman-Beta1-Exhaustive-Inventory.zip` and
`Yardman-Beta1-Building-Families-Checkpoint.zip`. Restore their newest versions
from the project's handoff alongside the canonical pack/conversion checkpoint.
Keep this ledger synchronized with each stable batch; document pending work
before any session ends.
