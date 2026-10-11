# Yardman

A Godot Android open-world game based on the full island of Jamaica. One real metre remains one world metre horizontally and vertically. All fourteen parishes are first-class. The active branch is `codex/godot-polish-002`; runtime source lives in `godot/`. Unity source is preserved as historical work and is not the active build path.

The current work order is exhaustive Beta 1 asset recovery and validation, then independent Beta 2 inventory and quality replacements, then continued game polishing before final packaging. Keep tested source pushed and internal Android CI green throughout. An APK is a checkpoint, never project completion. See [execution doctrine and coverage](godot/docs/ASSET_EXECUTION.md).

The current traversal milestone adds registered national terrain, a persistent road graph, bounded terrain/road streaming, a rebased local origin, a third-person pedestrian, an original drivable vehicle with entry/exit, independent multi-touch controls, saves with backup recovery, five graphics profiles and access to every parish. Geographic breadth is island-wide; street-level fidelity remains early. This is not a finished game or a claim of shipping visual quality.

The real OSM dataset contains 59,389 drivable ways, 120,231 logical edges and 712 road tiles. The initial Copernicus terrain representation contains 1,416 shared-edge tiles at 64 m runtime sample spacing. Roads and terrain use EPSG:3448; saves retain projected double-precision coordinates. See [terrain](godot/docs/TERRAIN.md), [roads](godot/docs/ROAD_GRAPH.md), [streaming](godot/docs/STREAMING.md) and [gameplay](godot/docs/GAMEPLAY.md).

## Android

[GitHub Actions Android builds](https://github.com/rell28194-rgb/yardman/actions/workflows/godot-android.yml) retain an internal test APK, checksum, source manifests, recovery gate report and diagnostic logs. Android is arm64-v8a, package `com.rell.yardman`, using Godot 4.7.2 stable and GL Compatibility. New runs use the **Yardman-Internal-Android** artifact. These builds maintain compatibility while harvesting continues; terminal APK delivery is deferred until the asset and polish gates pass. See [build instructions and validation](godot/docs/ANDROID.md).

Touch supports independent movement/steering, throttle and camera input. See [controls and HUD](godot/docs/CONTROLS_HUD.md) for the current layout and behavior. Keyboard: WASD/arrows, E enter/exit, Shift sprint, F5 save, R recover.

## Validation

CI runs Python road/terrain tests, Godot import and boot, national streaming/graph tests, fourteen-parish traversal/gameplay/save/mobile-input checks, Android export, packaged-resource checks and APK signature verification. Local software OpenGL rendering is inspected separately. Android device frame rate and thermals require actual device evidence; host test results do not establish them.

## Data and expansion

OSM roads retain source node/way identity, adjacency and metadata independently of rendered tiles. Terrain, roads and future buildings, vegetation, NPCs and jobs are separate streamed layers. Better data and assets can replace the same cells without shrinking or rebuilding the canonical world. [Drive context](godot/docs/DRIVE_CONTEXT.md) and the [data register](godot/docs/DATA_REGISTER.csv) record sources and current decisions. Required attribution is available in game.

Registered building footprints, coastal geometry and bridge/tunnel structures are implemented, with street-level fidelity and visual acceptance still open. Optional decoded sedan, foliage and surface/audio media live in the owner's private pack, outside public Git. Continue complete source-family classification, architectural recovery, material/atlas fixes, controls and geographic polish before later traffic/NPCs and jobs. Credentials and signing files remain outside source control.
