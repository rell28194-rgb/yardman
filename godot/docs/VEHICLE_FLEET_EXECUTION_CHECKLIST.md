# Yardman Vehicle Fleet Execution Checklist

Authority date: 2026-10-29

This checklist governs all complex vehicle work. The project scope is the full recoverable Beta1 + Beta2 vehicle universe. A representative car is a validation fixture only; it is never the fleet scope.

## Phase A — source inventory and identity

- [ ] Inventory every vehicle-capable source container in Beta1 and Beta2.
- [ ] Resolve root vehicle families, not individual mesh/material objects.
- [ ] Resolve make/model/generation/variant where source evidence permits.
- [ ] Keep unresolved identities quarantined instead of guessing.
- [ ] Deduplicate the same physical vehicle across sources while preserving every richer dependency source.
- [ ] Preserve source unit, object IDs, hashes, archive path, source game and recovery evidence.

## Phase B — dependency closure per vehicle

A vehicle does not pass recovery until every applicable domain is either recovered or explicitly proven absent.

- [ ] exterior body geometry
- [ ] panel/body variants
- [ ] high/low LODs
- [ ] complete interior
- [ ] dashboard / steering wheel / seats
- [ ] stock wheels and optional wheels
- [ ] tyres
- [ ] brake discs/calipers
- [ ] wheel anchors / suspension anchors
- [ ] glass
- [ ] headlights / taillights / emissive state
- [ ] trim/chrome/carbon
- [ ] paint/material families
- [ ] source textures and UV bindings
- [ ] collision / body bounds
- [ ] camera points
- [ ] driver seat
- [ ] exit point
- [ ] exhaust / flame / smoke points
- [ ] particle hooks
- [ ] source animation data
- [ ] engine / intake / exhaust audio
- [ ] transmission / turbo / supercharger audio where present
- [ ] tyre / skid / suspension audio where present
- [ ] physics / powertrain / gearing data
- [ ] steering / brake / grip data
- [ ] upgrade stages
- [ ] body kits / bumpers / spoilers / bonnets / exhaust options
- [ ] rims / tyres / fitment customization
- [ ] paint / livery / tint customization
- [ ] source camera/inspection behavior where useful
- [ ] runtime lifecycle: spawn, drive, park, exit, re-enter, reset, despawn

## Phase C — neutral source-max pack

- [ ] Preserve source hierarchy; do not flatten to one hero mesh.
- [ ] Preserve named source anchors and transforms.
- [ ] Preserve separate movable/customizable parts.
- [ ] Preserve authored LOD relationships.
- [ ] Translate materials to Godot without losing semantic surface identity.
- [ ] Generate provenance manifest and dependency manifest.
- [ ] Generate Godot scene wrapper and vehicle definition.
- [ ] Generate vehicle-specific dynamics profile.
- [ ] Generate customization and upgrade descriptors.

## Phase D — Godot integration gate

- [ ] exact identity displayed
- [ ] no cross-model fallback
- [ ] correct metre scale
- [ ] correct wheelbase / tracks / tyre radius
- [ ] correct wheel steering/spin
- [ ] collision aligns to body
- [ ] lamps work
- [ ] interior reads correctly
- [ ] inspection scene works
- [ ] camera and seat points work
- [ ] vehicle-specific dynamics loaded
- [ ] customization states switch without orphan geometry
- [ ] upgrades alter the intended systems only
- [ ] audio responds to RPM/load/gear/surface
- [ ] park / exit / re-entry / reset / despawn pass
- [ ] no duplicate/orphan nodes
- [ ] selector-safe metadata
- [ ] Android performance budget recorded

## Phase E — visual acceptance

- [ ] exterior silhouette inspection
- [ ] panel curvature / normals
- [ ] realistic paint / clearcoat
- [ ] glass thickness/tint
- [ ] light internals and emissive behavior
- [ ] wheel depth / tyre sidewalls / brakes
- [ ] interior completeness/readability
- [ ] contact shadow / stance
- [ ] LOD transition inspection
- [ ] customization inspection
- [ ] upgrade inspection
- [ ] night/day/weather inspection

A car loading is not acceptance. A GLB existing is not recovery. A mesh named after a car is not a vehicle.

## Self-critique requirement

Every substantial vehicle commit or checkpoint must record:

1. what was attempted;
2. what evidence was used;
3. what passed;
4. what failed or remains unverified;
5. what assumptions were made;
6. what would falsify the current conclusion;
7. the next highest-value repair.

No vehicle may be described as complete, accepted or source-faithful when any required dependency domain is unresolved.
