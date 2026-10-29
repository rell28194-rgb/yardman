# Yardman vehicle work — self-critique and failure prevention

Date: 2026-10-29

This file records process failures that must not be repeated.

## What failed in the CarX Fusion experiment

### 1. Filename-led recovery instead of dependency-led recovery

Failure:
A mesh or member was located because its name appeared to match a vehicle, then it was transplanted into a host slot without proving the complete dependency closure.

Observed consequence:
- one donor surfaced while others remained hidden or unloadable
- donor appearance differed sharply from its original game
- host-slot materials, wheels, interiors or rigs remained where donor-specific dependencies were missing
- structural parse success was mistaken for runtime completeness

Correction:
Start from the source vehicle's root prefab/entity/config and traverse outward until every referenced geometry, material, texture, rig, audio and configuration dependency is accounted for. The dependency manifest is the deliverable; the mesh is only one entry.

### 2. Host-slot substitution hid missing source work

Failure:
Existing host physics/material/wheel/camera systems were reused to make a donor look superficially integrated.

Observed consequence:
Vehicles could be described as transplanted while still behaving or rendering like the host car beneath them.

Correction:
Yardman is not constrained by old CarX slot budgets. Build a dedicated Godot vehicle scene from the donor's complete recoverable source. Reuse Yardman systems only through explicit adapters with source-derived data.

### 3. Static validation was overvalued

Failure:
ZIP CRC, AssetRipper reparse, valid GLB export, member hashes and successful packaging were treated as strong evidence of gameplay quality.

Observed consequence:
Device inspection exposed missing bodies/materials, hidden vehicles and track/runtime failures that static tests did not predict.

Correction:
Static validation is necessary but never sufficient. Vehicle acceptance requires visual inspection, interactive driving, customization/upgrade behavior and lifecycle tests.

### 4. Source-max fidelity was lost too early

Failure:
Donor geometry was forced into fixed native mesh allocations and source material channels were collapsed to host limits.

Observed consequence:
The result could no longer reproduce the original vehicle faithfully even if later systems were fixed.

Correction:
Preserve source-max masters first. Generate Yardman LODs from the masters. Never make an old host format the ceiling for a Godot vehicle.

### 5. Runtime code and data were mixed conceptually

Failure:
There was a tendency to treat source-game behavior as something that could be copied by moving assets or patching a few values.

Correction:
Recover source code/configuration as behavioral evidence where legally/technically available, but port the behavior deliberately into Godot systems. Engine-specific lifecycle, serialization, shader and physics code does not become correct Godot code by copying it.

### 6. Repo lanes became misleading

Failure:
Branch names implied vehicle/world authority even when the actual Godot runtime was restored indirectly through CI artifacts. Separate CarX experiments also lived in the Yardman repository as build infrastructure, increasing ambiguity.

Correction:
`codex/yardman-vehicle-master-20261029` is the canonical vehicle recovery lane. Every continuation document must name the actual branch/head and source packs. CarX Fusion is reference-only and must not become Yardman runtime code.

### 7. Completion language was too strong

Failure:
Words such as validated, repaired or authoritative were sometimes used for a narrow subset of checks.

Correction:
Use staged status vocabulary from `VEHICLE_MASTER_CHECKLIST.md`. State exactly which gate passed and which did not. No ACCEPTED label without owner/device evidence where relevant.

## Yardman Fleet64 critique

The existing Fleet64 pipeline proved useful infrastructure: packaging, selector/garage switching, lifecycle hooks and Android export. It does NOT prove that 64 vehicles are high-fidelity source reconstructions. Treat the existing Fleet64 entries as runtime/selector baselines until each vehicle is matched to an authoritative Beta 1/Beta 2 dependency pack and passes the new checklist.

## Mandatory critique after each complex task

Every substantial vehicle task must end with these questions answered in its evidence report:

1. What did we actually prove?
2. What did we only infer?
3. Which source dependencies remain unresolved?
4. Which visual differences from the source game remain?
5. Which behavior/customization differences remain?
6. Did any conversion destroy source detail?
7. Did we accidentally reuse a placeholder/host asset?
8. Did we test the failure path, not only the happy path?
9. What would an owner video most likely expose as wrong?
10. Is the artifact durable enough that another chat can reproduce the result without conversation memory?

If any answer is unknown, record UNKNOWN. Do not convert uncertainty into a claim.
