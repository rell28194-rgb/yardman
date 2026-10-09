# Yardman

A Unity project for a full-scale Jamaica simulation. One world metre remains one metre. All 14 parishes retain equal project priority.

This first source checkpoint implements the **ARCH-PROOF-001 technical foundation**. It includes 144 synthetic 1 km cells, deterministic content compilation, floating origin, cancellable predictive streaming, collision-readiness gating, persistent entity identity, event scheduling, and an Android build entry point.

**The architecture gate is still open.** The Unity runtime has not yet been compiled or measured on Android. The synthetic terrain, straight roads and traversal cube are test fixtures, not Jamaican geographic coverage or the game's intended visual quality. See [current status](Docs/STATUS.md) and [engine decision](Docs/ENGINE_SELECTION.md).

## Source layout

| Path | Responsibility |
| --- | --- |
| `Assets/Yardman/Domain` | Double-precision coordinates, cell IDs, origin frame and entity IDs |
| `Assets/Yardman/Content` | Versioned manifest contract and dependency validation |
| `Assets/Yardman/Streaming` | Predictive requests, cancellation, retries, bounded integration and readiness |
| `Assets/Yardman/Simulation` | Persistent entity state and deterministic event scheduling |
| `Assets/Yardman/Runtime` | Unity meshes, collision, async content loading, traversal harness and telemetry |
| `Assets/Yardman/Editor` | Scene generation and Android build methods |
| `Tools/jmworld` | Standard-library Python content compiler and candidate source registry |
| `Assets/StreamingAssets/Yardman` | Committed, hashed synthetic content ready for cloud checkout |
| `Cloud` | Build Automation target configuration; no credentials |
| `Tests` | Compiler, cloud-client and standalone C# contract tests |

## Verification

Python 3.10+ and either .NET 8 SDK or Mono are sufficient for the standalone tests:

```sh
bash Tools/test.sh
bash Tools/build_content.sh
python3 Tools/sync_meta.py
```

GitHub Actions runs these checks on pushes and pull requests. No Unity license is needed for these core checks.

## Unity and Android

Open the project with the provisional editor version in `ProjectSettings/ProjectVersion.txt`. On first interactive import, the editor script creates `Assets/Yardman/Generated/StreamingProof.unity`. The menu **Yardman → Create streaming proof scene** regenerates it. This deliberately replaces the open scene, so save other scene edits first.

For a licensed editor with Android IL2CPP support:

```sh
mkdir -p Builds/Android
Unity -batchmode -quit -projectPath . -buildTarget Android \
  -executeMethod Jamaica.Unity.Editor.YardmanBuild.Android \
  -logFile Builds/Android/editor.log
```

The development APK target is `Builds/Android/Yardman-Proof.apk`. The cloud pre-export method is `Jamaica.Unity.Editor.YardmanBuild.PreExport`. See [cloud continuation](Docs/CLOUD_BUILD.md).

The runtime drives a synthetic corridor at 70 m/s for 1,800 seconds, waits when collision is unavailable, rebases near the traversal probe, and writes telemetry, a result envelope and an entity save under `Application.persistentDataPath`. The default run is automatic. On-screen Performance / Balanced / Quality / Ultra / Custom controls currently exercise shadow, LOD, AA and camera-distance settings; density, vegetation, NPC and traffic scaling awaits those systems.

## Content rules

The compiler accepts only `SYNTHETIC_TEST_ONLY` fixtures in this checkpoint. Its zero anchor and `SYNTHETIC_METRES` datum are explicitly **not** Jamaica's canonical coordinates. Accepted real source acquisition, CRS transformation and PostGIS integration remain separate work.

Every artifact is addressed by its SHA-256 hash. Build keys include compiler code, schema, relevant source fragment, target, options, asset-library version and dependencies. A road-width edit rebuilds its road artifact without rebuilding unchanged terrain. Corrupt cached artifacts are quarantined and rebuilt.

External sources can be registered with provenance and rights metadata and placed in a candidate changeset. There is no automatic path from a candidate to accepted geography.

Runtime credentials come from secret environment injection only. `.env.example` contains variable names and public project identifiers. Never put secret values, authorization headers, tokens or signing keys in source files or artifacts.
