# Yardman Beta 1 / Beta 2 source authority

Date: 2026-10-29

## Authoritative source locations

Use the owner's connected Google Drive archives as the canonical donor source. Do not substitute loose files from old CarX Fusion experiments, renamed exports, screenshots, or guessed internet downloads.

### Beta 1

Path family:
`/Google Drive/Yardman beta/beta.7z.001` … `/Google Drive/Yardman beta/beta.7z.151`

Observed split layout:
- parts 001–150: 25,165,824 bytes each
- part 151: 18,741,457 bytes

Beta 1 already has durable recovery work in the Library, including the exhaustive inventory and source-classification/family queues. Reuse those checkpoints where identities match instead of re-decoding expensive source batches unnecessarily.

Known Beta 1 source families include CarX/Highway and other recovered game/source containers. Every vehicle must be traced to its enclosing game/package and then to all referenced dependencies before conversion.

### Beta 2

Path family:
`/Google Drive/Yardman beta/Beta2/beta2.7z.001` … `/Google Drive/Yardman beta/Beta2/beta2.7z.232`

Observed split layout:
- parts 001–231: 52,428,800 bytes each
- part 232: 15,990,987 bytes

Beta 2 is explicitly in scope under the 2026-10-29 owner directive. The previous milestone rule that kept Beta 2 locked until Beta 1 completion is superseded for the vehicle-recovery lane.

Previously recovered RR3 evidence includes complete source families/components for at least:
- 2012_audi_r8_lms
- 2014_audi_r8spyder
- 2017_bmw_m4_dtm
- 2017_mercedes_c63_dtm
- 2018_audi_r8_gt4
- 2018_bmw_m4_gt4
- 2021_bmw_m4_gt3

These are recovery evidence, not automatic Yardman acceptance.

## Required decomp/recovery output

The goal is not a pile of extracted files. The durable recovery output for each source game must contain:

1. package/version identity and hashes
2. complete archive/object inventory
3. type/class inventory when the source engine format supports it
4. dependency graph or best available reference graph
5. vehicle-family index
6. per-vehicle dependency manifests
7. raw source bytes or durable references to the exact source members
8. decoded neutral masters where conversion is understood
9. conversion reports and failure logs
10. source-to-Godot mapping reports

Large raw/decoded binaries belong in persistent Library/Drive checkpoints with hashes. Git stores manifests, scripts, schemas, reports and small test fixtures.

## Source preservation rules

- Never overwrite the only raw recovered copy with a converted or simplified asset.
- Preserve original coordinate system, units, material names, object names and source hierarchy in metadata even when Godot needs normalized values.
- Preserve every useful LOD. Do not discard high-detail source geometry because Android later needs lower LODs.
- Preserve all texture channels/maps before repacking to KTX2 or another Godot/mobile format.
- Preserve customization/upgrade variants as separate source evidence, not flattened into one body.
- Preserve audio event/bank relationships where available, not only decoded WAVs.
- Record source uncertainty rather than guessing vehicle identity from filenames.

## Runtime boundary

Yardman stays Godot 4.7.2. Donor executable/runtime code from Unity or other engines is evidence for behavior and configuration, not code to paste blindly into the Godot runtime. Recreate the behavior with Yardman systems while preserving measurable source data and presentation.
