# Yardman source-max vehicle pipeline

This pipeline exists to prevent mesh-only imports.

## Inputs

Authoritative source archives are registered in `source_registry.json`.

Large raw source bytes and decoded masters should be stored in persistent Library/Drive checkpoints. Git stores scripts, manifests, hashes, small fixtures and reports.

## Per-source-game flow

1. Reconstruct/identify exact source package from Beta 1 or Beta 2.
2. Hash package and inventory every file/object relevant to vehicle recovery.
3. Recover catalog/entity/prefab data before assigning identities from filenames.
4. Build a vehicle-family index.
5. For each vehicle, start from the source root prefab/entity/config and traverse references.
6. Populate every category in `vehicle_manifest.schema.json`.
7. Run `audit_vehicle_manifest.py` before status promotion.
8. Decode a source-max neutral master without destructive simplification.
9. Build the Godot vehicle from that master.
10. Derive runtime LODs/textures from the preserved master.
11. Run structural, visual, driving, customization, Android and owner/device gates as applicable.

## Manifest statuses

- `DISCOVERED`: candidate identity/source only; unresolved dependencies expected.
- `RECOVERED`: dependency categories have been accounted for; no required category may remain silently unresolved.
- `CONVERTED`: source-max neutral master exists with conversion report.
- `INTEGRATED`: dedicated Godot scene and interaction hooks exist.
- `GAME-READY`: structural + driving gates pass.
- `HIGH-FIDELITY`: visual + customization/source-parity gates pass.
- `ACCEPTED`: owner/device acceptance passes and no critical unresolved defect remains.

## Example auditor usage

```bash
python Tools/vehicle_pipeline/audit_vehicle_manifest.py path/to/vehicle.json
python Tools/vehicle_pipeline/audit_vehicle_manifest.py manifests/*.json
```

The auditor intentionally fails closed. `source_absent` and `not_applicable` require evidence; they are not escape hatches for missing recovery work.

## Godot mapping principles

- Dedicated vehicle scene per source vehicle/family.
- No forced conversion into another car's fixed mesh/material budget.
- Preserve authored dimensions and pivots unless a measured correction is documented.
- Keep paint, glass, lights, tyres, brakes and interior as semantic material/object families.
- Keep customization variants data-driven and reversible.
- Source tuning/upgrades map to explicit Godot runtime parameters; do not make cosmetic UI with no physics effect.
- Preserve high-detail inspection/garage assets independently from gameplay/traffic LODs.
- Audio mapping keeps RPM/load/event semantics where the source provides them.

## Durable output layout

Recommended persistent pack layout for each vehicle:

```text
vehicle_id/
  manifest.json
  raw_refs/
  source_master/
    geometry/
    textures/
    audio/
    data/
  conversion/
    report.json
    neutral/
  godot/
    mapping.json
  validation/
    structural.json
    visual/
    driving.json
    customization.json
    android.json
    owner_device.json
  critique.md
```

Do not use conversation history as the only place where recovery decisions live.
