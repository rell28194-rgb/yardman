# Reconciliation Beta asset reuse checkpoint — 2026-10-22

Branch baseline before this documentation commit: `a57411954c40c99d3f14f6ca56a6229280a4c10f`.

This checkpoint records only validated runtime/source work. It does not mark Beta 1 or Beta 2 complete, does not establish Android-device acceptance, and does not authorize geographic claims from presentation assets.

## Green reconciliation reuse

The world-reconciliation lane now consumes more recovered private media through asset-absent-safe hooks while preserving Jamaica's registered geometry and streaming authority:

- Beta 2 uCaptain scrub-grass albedo/normal and mountain-terrain albedo through semantic terrain bindings.
- Beta 2 WaterBump as optional ocean micro-normal detail.
- Beta 1 `ground_rock_alternate.png` as one bounded dominant-axis near-field rock sample.
- Beta 1 `water_foam_japan.png` as one bounded alternate foam-detail sample on the existing registered-ocean shader.
- Beta 1 `building_concrete.png` in an existing deterministic wall-material family with no new building footprint, node or draw batch.
- Beta 1 recovered neutral settlement props: waste bin, fire hydrant and metal cabinet, only from registered road-facing building frontage, compiled road geometry and registered terrain height.
- Beta 1 recovered palm short/curved variants by substituting the near mesh of existing palm MultiMesh cells. Existing anchors, instance counts, distant proxies and draw-call counts remain unchanged.
- Beta 1 recovered drive/gravel/grass/skid audio sources routed through the established four-player audio budget.
- Beta 1 `footsteps.wav` used as an optional cadence-triggered one-shot on the existing footsteps player; asset-absent builds retain the existing loop fallback.
- Beta 1 `road_driver_seated.glb` attached only to the accepted reference Crown visual at the measured RHD fit `(0.91, 0.21, -0.187)` m. It is presentation-only, visible only while occupied, with collision/physics/handling/fleet mutation disabled. Animation retarget and Android acceptance remain pending.
- Beta 1 `Medium_Stone_01` and `Medium_Stone_02` recovered into private aliases `terrain_boulder_01.glb` / `terrain_boulder_02.glb`. The runtime places at most eight per 4 km road tile and two per 256 m cell, only on registered terrain with 18–125% sampled grade, outside a 22–48 m road-clearance envelope and at least 10 m from known water. Bridges/tunnels are rejected. This is presentation inference, not geology truth; terrain mutation and collision are disabled.

## Current validation

At source `a57411954c40c99d3f14f6ca56a6229280a4c10f`:

- World reconciliation run `39861517783`: SUCCESS. Import, recovered audio, terrain, optional Beta bindings, street furniture, palm variants, steep-slope boulders, groundcover, built environment, road edge, vegetation LOD, v2 hydrology, geometry guard, bridge and tunnel gates all passed.
- Core run `39861517836`: SUCCESS. Compiler/manifest/streaming/simulation checks and committed-content regeneration/verification passed.

Earlier source slices for alternate foam, seated driver and cadence footsteps were separately gated before the boulder checkpoint; the boulder run re-executed the complete reconciliation suite including those current files.

## Private pack durability

`Yardman-Personal-Reference-Assets-002.zip` is saved in the project Handoff Library. It preserves the prior private reference pack plus the two recovered boulder aliases and their provenance records. Public Git remains media-free; missing private files must continue to fall back safely.

## Deliberate non-promotions

Do not place recovered construction cones, portable fencing or concrete barriers until the world pipeline retains explicit construction/work-zone truth. The current road compiler filters `highway=construction`, so random work-zone placement would be fabricated.

Do not use recovered foreign sign faces. The inspected Highway sign atlas contains non-Jamaican/fantasy semantics; support geometry may only be reconsidered with Jamaica-specific faces and authoritative sign context.

Do not place bus stops, traffic lights or semantic warning/bridge signs from name matches alone. Their target inventories are recovery leads, not Jamaican location truth.

Generic Car Mechanic park benches are promising (`sharedassets6.assets` mesh records `Parkbench-01`, `Parkbench-02`, `Parkbench-05`), but their target batch preserves inventory metadata rather than the required `sharedassets6` source container. The surviving model-conversion cache does not contain `sharedassets6`. Do not fabricate GLBs from mesh headers. Resume bench recovery only when the original source bytes or a complete linked extraction checkpoint is available.

Workshop tool families are fully recovered in the Mechanic linked-workshop checkpoint, but this reconciliation branch currently has no stable garage/workshop scene root. Keep those assets for a garage/interior lane rather than scattering them outdoors.

## Next recovery priority

Prefer newly recoverable neutral settlement/infrastructure modules with source bytes and defensible placement: benches, electrical boxes, neutral trash/container variants, non-semantic lighting/support geometry and storefront components. Every promoted family must remain bounded for Android, preserve source/provenance, and be attached to registered Yardman context rather than foreign source-map placement.
