# Owner feedback and v0.3 polish gate

The owner played the delivered Android v0.2 and confirmed the large national map functions. They rated it 2/10 for presentation and control quality. Performance on their device was not the reported problem; visible geometry glitches, inaccurate shoreline/water, poor controls and unrealistic roads were.

The accepted direction remains all fourteen parishes, deterministic EPSG:3448 registration and real metre dimensions. Godot remains the engine. This iteration must preserve the national model while repairing the map, HUD, car and traversal experience. No Unity credential reuse is authorized.

## Implementation

- Road format3 joins ribbons before clipping, preserves source-way UV station and width metadata across terrain/tile seams, bounds miter joins, and avoids duplicate edge ownership. Shaders use filtered asphalt/markings and controlled depth offsets. Local surface queries affect vehicle grip; logical graph identity persists across render eviction.
- Shoreline masks derive from assembled OSM coast rings. Complete land cells and exact clipped partial triangles supply the same visible terrain and collision. Ocean geometry is the land complement at sea level. Sand appears on sourced beach polygons; no guessed island-wide sand belt. Distant overview sectors complement resident terrain.
- The compact HUD follows the prepared input/UI specifications: dynamic walking stick, independent look/sprint, Stick driving default with Buttons/Wheel options, separate pedals/reverse/handbrake, contextual interaction, radar, compass and speed. Travel, graphics, recovery and credits live in a blocking drawer. Input preferences persist separately from world progress.
- The original sedan replaces blockout geometry. Acceleration, independent service braking, limited reverse, speed-dependent steering, grass drag/grip, wheel motion, lamps and suspension presentation replace the fixed-speed lawn traversal. This remains a kinematic driving model, not a full tyre/damage simulator.
- Original shaders/noise and mesh plants replace uniform grass/stick palms. Regional colour is an explicitly approximate visual proxy, not measured land-cover data. Trees sample resident terrain and respect nearby source roads. The indexed cell building layer uses real OSM footprints with recorded source height/level status; fallback heights, facades, roof colours and windows are original inferred presentation.

## Evidence and limits

Compiler tests cover road joins, widths/UVs, clipped ownership, exact terrain planes, coastline holes/land complements and source beach behavior. Isolated runtime tests cover surface indexing/eviction, multi-touch/menu blocking/layout, vehicle contact/braking/reverse/grip, and foliage/material generation. Actual Compatibility GL rendering exposed two bugs missed by headless checks: black default MultiMesh colours and an indexed batch that omitted custom car panels. Both have regression coverage.

The integrated scene must additionally pass all-parish terrain contact, joystick movement, menu pause, independent settings save/load, rebase/save continuity, source-road grip, streamed building lifecycle and source-data packaging. Captures come from the actual Godot scene. Android CI must export and validate the exact milestone commit before APK delivery.

Visual acceptance remains open until actual scene review and owner play. Coarse64m DSM, source OSM completeness, unsurveyed materials/building heights, bridge/tunnel decks, traffic/NPCs, jobs/economy, full animation, audio and weather remain limitations. Improved source geometry and shaders do not establish the requested high-quality finished art gate, phone FPS or thermals.

## Saved state

Polish branch: `codex/godot-polish-002`. Preserve green v0.2 (`9411a40`, run37983947182) until integrated CI is green. Generated national data is reproducible build output and is excluded from Git. Save focused source checkpoints frequently; a workspace reset previously lost uncommitted polish and required reconstruction.
