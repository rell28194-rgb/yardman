# Active Godot checkpoint — 2026-10-10

The production runtime is Godot 4.7.2 / GL Compatibility on `codex/godot-beta-001`. The material below the historical divider records the previous Unity proof and does not control current engine selection or authentication.

The owner installed and played v0.2. They confirmed national traversal worked and reported smooth Ultra play, but rated its presentation **2/10**: inaccurate cyan water/beaches, irregular/glitching roads, oversized HUD, weak walking controls, basic car and unrealistic grass driving. Their feedback is a required polish gate, not acceptance of the finished game. Reported device FPS is owner observation, not a controlled performance benchmark.

Active polish work continues on `codex/godot-polish-002`, preserving the green v0.2 branch until the integrated milestone passes. Source checkpoints `5988dd4`, `e323c39` and `e83f424` save the road compiler, sourced shoreline, original art, compact HUD, independent analog controls and revised vehicle. Thirty Python compiler tests and isolated Godot surface/control/vehicle/art tests passed. Actual GL fixture rendering exposed and repaired black vegetation and an indexed-mesh batching bug that omitted the car shell. Full streamed-world visual review and the new Android build remain pending; no v0.3 APK is claimed at this checkpoint.

Read `godot/docs/POLISH.md`, `COASTLINE.md`, `CONTROLS_HUD.md`, `VEHICLE.md`, `VISUAL_POLISH.md` and `BUILDINGS.md` alongside the architectural docs. The latest owner handoff requires Godot and prohibits reusing prior Unity credentials.

The actual failed Android export in run `37969188477` was repaired by enabling ETC2/ASTC and explicitly packaging road JSON. Recovery commit `aa26c35` and road-continuity commit `cd0da9a` both completed green Android builds. National graph/streaming run: https://github.com/rell28194-rgb/yardman/actions/runs/37977755522.

The built milestone includes registered Copernicus terrain, all-parish road spawns, safe streamed collision, pedestrian movement, vehicle entry/exit/driving, multi-touch, rebased projected-coordinate saves, corruption recovery and five quality profiles. Local gates passed: 15 Python tests, Godot boot, graph/streaming, all fourteen parish visits, walking/driving/entry-exit, save/backup and input checks. A real software OpenGL frame rendered; a signed arm64 APK exported and passed resource/ABI/signature validation. Android CI completed green at `9411a40b79ead3f54f789475aab87355778f4feb`: https://github.com/rell28194-rgb/yardman/actions/runs/37983947182. Run `37983947182` passed 15 Python tests, import, smoke boot, streaming, all-parish gameplay, export, packaged-resource validation and signing. Its arm64 APK is 181,511,770 bytes; SHA-256 `46fad912f85eef1ac0f8420ded04824b6774090d2d087e9d62b52e0d49dcddac`. APK artifact ID: `11642327607`. Local software OpenGL rendering succeeded. A software-only Android 35 emulator was attempted without KVM but did not complete OS boot within 240 seconds; that automated attempt supplies no Android installation/launch evidence. The owner subsequently confirmed installation and actual play of the delivered v0.2 APK; sustained frame-time, memory and thermal results are still unmeasured.

Read `godot/docs/ANDROID.md`, `TERRAIN.md`, `ROAD_GRAPH.md`, `STREAMING.md`, `GAMEPLAY.md` and `DRIVE_CONTEXT.md`. Full-island geography and real metre scale remain the canonical model. Terrain is a coarse DSM shell, not surveyed bare earth. Art, building detail, traffic/NPCs, economy/jobs and device performance remain unfinished; the visual-quality gate is open.

---

## Historical Unity source checkpoint

# Source checkpoint — 2026-10-09

ARCH-PROOF-001 status: **implemented in source; Unity/Android execution pending**.

| Evidence | Result |
| --- | --- |
| Original repository inspected | Initial commit contained the existing LICENSE only; preserved |
| Python compiler contract tests | 18 passed |
| Python cloud-client tests | 6 passed; no live API requests |
| Standalone C# core and manifest tests | 30 passed under Mono, C# 7.2 |
| Generated content | 144 synthetic cells; 288 hash-verified artifacts |
| Second unchanged content compile | 288 cache hits; 0 rebuilt; 0 repaired |
| Simulated traversal | 1,800 simulated seconds, 125,997.20 metres, 37 rebases, 2 startup safety holds, peak 20 stream entries |
| Unity editor compilation | Not run; editor unavailable in execution environment |
| Android cloud build/APK | Not run; cloud authentication unresolved |
| On-device frame time, memory and thermals | Not measured |
| Geographic coverage | 0 accepted cells in each of Jamaica's 14 parishes |
| Shipping visual-quality gate | Not evaluated; current scene is a technical fixture |

The fast standalone traversal uses immediate synthetic byte loads. Its simulated duration does **not** represent a 30-minute Android soak, real disk latency, Unity physics, rendered frame rate or thermal behavior. It validates state transitions, bounded residency, identity and coordinate behavior only.

## Implemented behavior

- Stable canonical cell IDs with negative floor indexing and half-open bounds.
- Double-precision world state isolated from Unity presentation coordinates.
- Content hashes, corruption checks, safe object paths, version gates and validated terrain/road dependencies.
- Cancellation-safe late completions, explicit timeouts, three-attempt retry limit, preserved request deadlines and bounded active work.
- Terrain-before-road integration and movement held until both collider layers are active.
- Persistent entity identity independent of presentation residency, optimistic versions and deterministic bounded event processing.
- Atomic local probe saves; telemetry and benchmark result output hooks.
- Android ARM64 / IL2CPP development build entry point and cloud target payload.

## Remaining architecture gate work

1. Restore cloud access, verify canonical project and effective permissions, and query available editors/build platforms.
2. Create or reconcile the cloud target against its actual API response, build an exact commit, inspect failures and repair them.
3. Compile the Unity adapter and test real async loading, collider integration, floating origin and save/reload on Android.
4. Run the sustained on-device benchmark with the project's full result schema, frame/memory/thermal evidence and failure thresholds.
5. Compare eligible engine candidates using the same fixture and then freeze the chosen editor/package lock.

Known scope limits: no geographic CRS implementation or accepted-source/PostGIS compiler; no real road graph, vehicle solver, NPC/traffic system, buildings or vegetation; no Unity play-mode test execution; integration is bounded by object count, not yet a measured millisecond budget. Real terrain edge normals and physics stress, pause/resume save durability, device resolution scaling and the complete benchmark schema remain to validate or extend.

## Preserved owner requirements

Choose the engine through evidence; Unity 7 remains eligible. Use cloud build machines, not Chromebook performance as the target. Maintain strong visual appeal in every shipping quality profile; reducing density or distance must not erase the game's identity. Synthetic empty terrain cannot satisfy the visual gate. Full-island scope and equal parish priority remain unchanged.
