# Yardman Render R&D Status

Branch: `codex/render-rd-001`
Production base: `codex/godot-polish-002` at `918616b290f961458d4508e664f12d82b8fb77da`
Engine: Godot 4.7.2. Production remains Godot; this lane does not authorize an engine switch.

## Current experiments

### Predictive streaming priority

- Adds precise world-position and motion-biased ordering to already-wanted road, terrain, and building queues.
- Does not expand residency radius or bypass thermal/quality budgets.
- Godot 4.7.2 import/test gate passes.
- Repository compiler/manifest/streaming/simulation contracts pass.
- Promotion status: R&D only until an Android traversal comparison shows materially lower forward-content latency without new frame spikes or memory growth.

### RenderingDevice visibility compute

- Vulkan Mobile compute shader classifies bounding spheres against six planes.
- Handles non-workgroup-aligned counts explicitly.
- Compacts visible instance indices with an atomic counter.
- CPU/GPU classification and compacted-index parity are hard correctness gates.
- Prior portability warning from runtime array length was removed; ObjectDB leak was removed.
- Synthetic CI uses Vulkan Forward Mobile on Mesa llvmpipe. These timings prove the code path and provide regression evidence, not Android-device performance.
- Promotion status: R&D only. Do not introduce synchronous per-frame CPU readback into production. A production GPU-driven path must keep visibility/compaction results GPU-resident or prove that a lower-frequency readback strategy wins on target Android hardware.

## Promotion doctrine

Promote an experiment only when it demonstrates a material win on the target workload, preserves full-island geographic/runtime correctness, stays inside Android memory/thermal budgets, and passes existing gameplay/render contracts. Otherwise keep it isolated or delete it.
