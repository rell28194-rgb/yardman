# Yardman R&D Research Lab — 2026-10-18

This is an isolated experimental lane for capabilities that Godot 4.7.2 does not expose directly, recent production rendering research, and LLM-assisted engineering workflows.

Production doctrine does not change:

- Godot 4.7.2 remains the engine.
- Full-island Jamaica remains the target.
- Android remains first-class.
- Research does not enter production because it is novel. It enters only after repeatable measured wins with no unacceptable quality or correctness regression.
- Existing working gameplay behavior is preserved unless an experiment specifically requires a controlled test harness.

## Promotion gate

Every experiment must have a frozen baseline and a candidate measured on the same workload, device class, settings, content, and camera/route where practical.

Hard failures override performance gains:

1. Any new crash, RID/ObjectDB leak, parser error, data corruption, collision/gameplay regression, missing geometry, or materially visible LOD/pop/flicker = **F / reject**.
2. Any benchmark whose candidate changes the workload, lowers content density without an explicit quality metric, or changes the oracle is invalid.
3. LLM-generated code and LLM-generated tests are not allowed to validate each other without an independent deterministic oracle.
4. Android/device measurements outrank desktop synthetic measurements for promotion.
5. A desktop or llvmpipe result may prove correctness or API feasibility, but not mobile performance.

Measured grade after correctness gates:

- **A+**: >=25% primary bottleneck improvement, or >=25% relevant memory/package reduction, with stable p95/p99 behavior and no material visual loss.
- **A**: 15–25% improvement.
- **B**: 8–15% improvement.
- **C**: 3–8% improvement or a useful win limited to a narrow workload.
- **D**: <3%, excessive complexity/power/memory cost, or benefit not repeatable.
- **F**: correctness, stability, visual parity, or device-support failure.

Secondary measurements are mandatory where relevant: CPU frame time, GPU frame time, p95/p99 frame time, resident memory, VRAM estimate, streamed bytes, integration time, draw calls, visible primitives, battery/power proxy, package size, and visual-diff metrics.

## Research findings: LLM-assisted engineering

### LLM-01 — Evaluator-driven algorithm/code evolution

**Research basis:** Google DeepMind's AlphaEvolve combines LLM-proposed code changes with automated evaluators and evolutionary selection. It has been used on measurable computing problems and production infrastructure rather than trusting one generated answer.

Source: https://deepmind.google/blog/alphaevolve-a-gemini-powered-coding-agent-for-designing-advanced-algorithms/

**Yardman use:** let an LLM propose bounded variants of measurable hot paths — streaming priority heuristics, culling thresholds, workgroup sizes, compact data layouts, batching rules, cache eviction weights, shader branches — then compile/run/test every candidate. Keep only variants that beat baseline and pass all correctness gates.

**Research priority:** A+

**First experiment:** evolutionary search over predictive-streaming scoring constants and GPU indirect workgroup/layout variants. The model proposes; the benchmark decides. No automatic production merge.

### LLM-02 — Independent test-first adversarial generation

**Research basis:** SWE-bench Verified evaluates patches with fail-to-pass and pass-to-pass tests. Recent 2026 research also warns that tests generated after faulty code can inherit the same mistake, reducing fault detection; independent tests are therefore required.

Sources:
- https://www.swebench.com/verified.html
- https://arxiv.org/abs/2607.05139
- https://arxiv.org/abs/2412.14137

**Yardman use:** a separate test agent generates adversarial routes and state transitions *before* implementation: parish seam crossings, rapid teleport chains, reverse-driving stream churn, tile load/unload oscillation, low-memory budgets, terrain/road/building arrival reordering, vehicle enter/exit chains, shader/quality toggles, malformed or partial compiled-world records.

Oracles remain deterministic and hand-specified: no NaNs, required collision resident, max retained tiles, max node/RID growth, no missing active-parish data, no gameplay-state loss, expected visible-count bounds, stable save/load state.

**Research priority:** A

### LLM-03 — Feedback-guided code/compiler optimization

**Research basis:** Meta's LLM Compiler was trained on LLVM IR/assembly for optimization and reports substantial recovery of autotuning potential. Other work shows compiler feedback improves optimization, but sampling/search can outperform a single feedback loop. HPC studies also show LLM optimization can generate incorrect code, so correctness testing is non-negotiable.

Sources:
- https://arxiv.org/abs/2407.02524
- https://arxiv.org/abs/2403.14714
- https://arxiv.org/abs/2503.13772

**Yardman use:** target things with objective metrics, not arbitrary style rewrites: offline world compiler kernels, native/GDExtension code if introduced, compute shaders, serialization loops, spatial-index builders, and data packing. Run compile/import/tests and benchmark each variant. Reject any patch that only looks faster.

**Research priority:** A-

### LLM-04 — LLM-guided fuzzing with reproducible oracles

**Research basis:** recent LLM fuzzing research uses models to create semantically valid seeds/drivers, while reliable systems require runtime reproduction and deterministic verification. FuzzingBrain V2 reports strong results using multi-agent analysis plus real fuzzers/reproduction rather than prose-only vulnerability claims.

Sources:
- https://arxiv.org/abs/2503.00795
- https://arxiv.org/abs/2605.21779

**Yardman use:** fuzz compiled map records, asset manifests, save files, route graphs, tile queues, job state, and renderer budget inputs. LLM provides high-semantic-value seeds; mutation and runtime assertions provide truth.

**Research priority:** A-

### LLM-05 — Asset recovery/QA copilot

Use multimodal/LLM classification to propose asset identity, semantic role, likely LOD family, material family, duplicate groups, naming repairs, and missing dependencies. Validation must come from dimensions, hashes, mesh statistics, material slots, texture channels, provenance ledger, and in-engine visual checks.

**Research priority:** B+

### LLM-06 — CI/log triage and regression localization

Use model ranking to correlate failure signatures with recent commits, changed systems, metrics, and known regressions. This improves engineering throughput but does not directly improve frame time.

**Research priority:** B

## Research findings: rendering / streaming / graphics

### GFX-01 — Mobile GPU-driven cluster LOD and streaming (NanoMesh-style)

**Research basis:** Tencent presented a mobile adaptive cluster renderer at SIGGRAPH 2024. It splits high-detail meshes into compact clusters, stores bounds/normal cones and merge error, performs GPU instance/cluster culling and LOD selection, streams clusters on demand, and reports an 80-million-triangle test scene on mobile. Their high-end mobile profile reported small culling costs relative to raster/material shading.

Source: https://advances.realtimerendering.com/s2024/content/Cao-NanoMesh/AdavanceRealtimeRendering_NanoMesh0810.pdf

**Yardman fit:** extremely high for Jamaica-scale buildings, roadside meshes, terrain detail and recovered high-detail assets. Yardman's current GPU indirect MultiMesh work is a useful first building block.

**Do not start by replacing the renderer.** First prove one bounded asset class:

1. offline cluster builder (target <=128 triangles/cluster);
2. compact cluster bounds + normal cone + geometric error;
3. compute frustum/backface/LOD culling;
4. indirect visible-list output;
5. on-demand cluster page residency;
6. compare against current MultiMesh/HLOD path on Android.

**Research priority:** A+

**Promotion requirement:** at least A-grade reduction in the actual target bottleneck or a major memory/streaming win. No visible cracks, missing clusters, or LOD pumping.

### GFX-02 — GPU HZB occlusion for indirect instance/cluster lists

**Research basis:** the mobile cluster pipeline uses HZB before finer cluster culling. Godot's built-in occlusion culling is CPU-based and the documentation notes that mobile can benefit strongly because its renderer lacks the Forward+ depth prepass.

Sources:
- Tencent mobile cluster rendering above.
- https://docs.godotengine.org/en/stable/tutorials/3d/occlusion_culling.html

**Yardman fit:** high for dense Kingston/Montego Bay scenes, roadside vegetation, traffic/parked proxies, and buildings. It can complement rather than replace Godot's CPU occlusion path.

**First experiment:** GPU depth-pyramid/HZB feasibility in a controlled RD scene, then cull the existing indirect roadside list. Measure cull cost, draw/primitive reduction, CPU savings, GPU savings, and false-occlusion rate.

**Research priority:** A

### GFX-03 — Virtualized terrain/material pages

**Research basis:** Call of Duty's large-scale terrain work virtualizes more than textures and scales from low-end mobile to high-end PC. This matches Yardman's 1:1 island requirement better than monolithic high-resolution terrain resources.

Source: https://www.advances.realtimerendering.com/s2023/index.html

**Yardman fit:** very high. Existing tiled terrain remains the stable baseline; experiment with finer virtual pages for height detail, normals/material masks, decals and local high-resolution detail rather than replacing the national tile coordinate system.

**Research priority:** A

### GFX-04 — Visibility-buffer / decoupled shading-rate research

**Research basis:** SIGGRAPH 2024 production research describes visibility-buffer rendering and shading-rate decoupling. Tencent's mobile path uses a compact 32-bit visibility buffer and material classification.

Source: https://www.advances.realtimerendering.com/s2024/index.html

**Yardman fit:** potentially high, but engine-intrusive in Godot 4.7.2. Keep as a microprototype only until lower-risk GPU-driven culling/LOD is proven.

**Research priority:** B (high upside, high integration risk)

### GFX-05 — Neural material/texture compression

**Research basis:** NVIDIA demonstrated neural compression of multiple material textures and mip chains with random-access real-time decoding, targeting much lower bitrates while preserving quality.

Source: https://research.nvidia.com/labs/rtr/neural_texture_compression/

**Yardman fit:** potentially significant because recovered/reference content is large, but the runtime decoder/hardware assumptions may not map well to broad Android GPUs or Godot 4.7.2.

**First experiment:** offline only. Benchmark representative Yardman terrain/building/vehicle material sets against ASTC/ETC2/Basis baselines for disk size, decoded quality and decode cost. Do not add a neural runtime until a portable decoder proves viable.

**Research priority:** B-

### GFX-06 — Neural Light Grid / learned irradiance representation

**Research basis:** Activision shipped a machine-learning-assisted irradiance-volume solution in Call of Duty titles, specifically motivated by constrained and low-end hardware and lighting-leak artifacts.

Source: https://advances.realtimerendering.com/s2024/content/Iwanicki/Advances_SIGGRAPH_2024_Neural_LightGrid.pdf

**Yardman fit:** technically relevant for future dense urban/night lighting, but current world fidelity, streaming, terrain and geometry bottlenecks are higher priority.

**Research priority:** B-

### GFX-07 — Temporal upscaling beyond current Mobile renderer limits

Godot 4.7 provides FSR2/TAA in Forward+ but not in the Mobile renderer. AMD's FSR 3 upscaler is open source and has Vulkan support, but full integration requires temporal inputs and deeper render-pipeline access.

Sources:
- https://docs.godotengine.org/en/stable/tutorials/rendering/renderers.html
- https://gpuopen.com/manuals/fidelityfx_sdk/techniques/super-resolution-upscaler/

**Yardman fit:** potentially useful for Android once geometry/streaming are stable. Prototype only in an isolated render path; do not fork core rendering solely for this until measured device profiling shows pixel shading is the limiting factor.

**Research priority:** B-

### GFX-08 — GPU decompression / direct-storage style streaming

GPU decompression is valuable on platforms that expose suitable APIs, but current broadly deployable Android/Godot 4.7.2 support is not strong enough to justify production work. Vendor-specific desktop Vulkan extensions are not an Android-first solution.

**Research priority:** D / watchlist

## Immediate experiment queue

1. **RDX-001: Roadside GPU indirect parity** — preserve all transform/color/custom payloads across near/far/grass, strict leak gate, raster-consumed indirect count. This is already active in the dedicated render R&D branch.
2. **RDX-002: Real camera frustum input** — replace synthetic fixed cube visibility with six real frustum planes and camera-relative distance. Grade on correctness first.
3. **RDX-003: HZB occlusion feasibility** — build/read a depth pyramid and add conservative sphere/AABB occlusion to the GPU visible-list stage.
4. **RDX-004: Cluster microbenchmark** — offline cluster a representative dense building/vegetation asset set, compute LOD/error/normal-cone metadata, compare CPU/GPU/memory against current mesh/HLOD.
5. **RDX-005: LLM test-first streaming fuzzer** — generate adversarial routes and data/state permutations independently from implementation; use deterministic project oracles.
6. **RDX-006: Evaluator-driven streaming autotune** — search priority weights/budgets under replayable national driving traces; optimize p95 integration latency and missed-ahead-tile count without increasing memory beyond contract.
7. **RDX-007: Virtual terrain page-cache microbenchmark** — small controlled region only; compare resident memory, upload bytes and transition artifacts against current tiles.
8. **RDX-008: Texture compression bake study** — ASTC/ETC2/Basis baseline versus research codecs/neural candidates; runtime integration only if portable Android decode is proven.

## Experiment record format

Each experiment commit or report must include:

- experiment ID and hypothesis;
- exact baseline SHA and candidate SHA;
- hardware/renderer/settings;
- dataset/route/camera trace;
- warmup and sample count;
- correctness and visual oracles;
- median, p95 and p99 where timing is involved;
- CPU/GPU/memory/package/streamed-byte metrics as relevant;
- before/after evidence;
- measured grade;
- decision: reject, iterate, or promotion candidate;
- cherry-pickable commit list if promotion is recommended.

Research results are evidence, not permission to merge.