# Yardman

A Godot Android open-world game based on the full island of Jamaica. One real metre remains one world metre horizontally and vertically. All fourteen parishes are first-class. The active branch is `codex/godot-beta-001`; runtime source lives in `godot/`. Unity source is preserved as historical work and is not the active build path.

The current traversal milestone adds registered national terrain, a persistent road graph, bounded terrain/road streaming, a rebased local origin, a third-person pedestrian, an original drivable vehicle with entry/exit, independent multi-touch controls, saves with backup recovery, five graphics profiles and access to every parish. Geographic breadth is island-wide; street-level fidelity remains early. This is not a finished game or a claim of shipping visual quality.

The real OSM dataset contains 59,389 drivable ways, 120,231 logical edges and 712 road tiles. The initial Copernicus terrain representation contains 1,416 shared-edge tiles at 64 m runtime sample spacing. Roads and terrain use EPSG:3448; saves retain projected double-precision coordinates. See [terrain](godot/docs/TERRAIN.md), [roads](godot/docs/ROAD_GRAPH.md), [streaming](godot/docs/STREAMING.md) and [gameplay](godot/docs/GAMEPLAY.md).

## Android

[GitHub Actions Android builds](https://github.com/rell28194-rgb/yardman/actions/workflows/godot-android.yml) retain the APK, checksum, source manifests and diagnostic logs. Android is arm64-v8a, package `com.rell.yardman`, using Godot 4.7.2 stable and GL Compatibility. Download a successful run's **Yardman-Beta-Android** artifact. Source code alone is not APK delivery. See [build instructions and validation](godot/docs/ANDROID.md).

Touch supports steering and throttle together. On foot the same controls become movement, and dragging looks around. Use the Enter/Exit, Save, Recover, region and quality controls. Keyboard: WASD/arrows, E enter/exit, Shift sprint, F5 save, R recover.

## Validation

CI runs Python road/terrain tests, Godot import and boot, national streaming/graph tests, fourteen-parish traversal/gameplay/save/mobile-input checks, Android export, packaged-resource checks and APK signature verification. Local software OpenGL rendering is inspected separately. Android device frame rate and thermals require actual device evidence; host test results do not establish them.

## Data and expansion

OSM roads retain source node/way identity, adjacency and metadata independently of rendered tiles. Terrain, roads and future buildings, vegetation, NPCs and jobs are separate streamed layers. Better data and assets can replace the same cells without shrinking or rebuilding the canonical world. [Drive context](godot/docs/DRIVE_CONTEXT.md) and the [data register](godot/docs/DATA_REGISTER.csv) record sources and current decisions. Required attribution is available in game.

Next layers include actual building footprints, land-cover-based vegetation, traffic/NPCs, jobs/economy, animation/audio/weather, surveyed shoreline and bridge/tunnel detail, and sustained Android profiling. Existing art and the kinematic vehicle are original early implementations, not the final fidelity target. No proprietary reference-game assets are redistributed. Credentials and signing files remain outside source control.
