# Yardman R&D Research Update — 2026-10-18 B

This update records new evidence gathered after the initial R&D lab was created and converts it into implementation rules for Yardman.

## Completed experiments

### RDX-002 — real-camera GPU roadside frustum

Status: **PASS for correctness/feasibility**.

The isolated Vulkan Mobile compute path now accepts a real camera position and six frustum planes rather than a hard-coded synthetic cube. A rotated/translated perspective camera is independently reproduced by a CPU oracle. Packed roadside records preserve transform, color/custom data, multi-surface indirect instance counts, and the existing Godot 4.7.2 command-buffer cleanup contract.

Grade: **A feasibility / performance ungraded**.

Reason performance remains ungraded: CI currently uses software Vulkan. That proves shader/API correctness and leak behavior, not Android GPU speed.

Promotion gate: Android hardware trace with CPU/GPU frame times, p95/p99, memory, visible-instance parity, and power/thermal observations.

### RDX-005 — adversarial streaming/retry oracle

Status: **PASS**.

A deterministic scenario harness was added for LLM- or human-proposed streaming failure sequences. The proposal format is schema-limited and cannot define its own assertions. Deterministic code remains the oracle.

The first test-first run reproduced two real defects before the policy was edited:

1. a tile that had already loaded could remain in the failure set until its previous retry deadline;
2. retry-attempt history could survive after a released failure later became unwanted, leaving orphan backoff state.

The retry policy now clears loaded failures immediately during service and drops orphan attempt history when tiles leave the wanted set. Diagnostics preserve existing counters and add dedicated loaded-failure and stale-attempt cleanup counters.

Grade: **A**.

Why: it found two real state-machine defects, rejects malformed proposals before mutation, replays deterministically, and remains independent of LLM-generated expectations.

## Critical Godot 4.7 renderer constraint

Godot 4.7's Compatibility renderer uses OpenGL and does **not** use RenderingDevice. Godot's Mobile and Forward+ renderers use RenderingDevice. The engine documentation also notes that the Mobile renderer is designed around mobile tile-based GPUs and has materially different constraints from desktop rendering.

Sources:
- https://docs.godotengine.org/en/4.7/engine_details/architecture/internal_rendering_architecture.html
- https://docs.godotengine.org/en/stable/tutorials/rendering/renderers.html

Consequence for Yardman: compute-based GPU-driven experiments are not a drop-in production replacement while the shipping lane remains Compatibility. Do not silently switch the project renderer.

Required architecture if GPU compute experiments win:

- preserve the current Compatibility path as the broad-device fallback;
- maintain an opt-in RenderingDevice/Mobile path for supported Android GPUs;
- keep the world/streaming data contracts renderer-independent;
- measure startup, visuals, shaders, memory, thermal behavior, and battery separately for both paths;
- promote only when the supported-device gain is large enough to justify the additional path.

This is an engine capability split, not an engine switch.

## New LLM research findings

### Runtime-guided evolutionary optimization is stronger than one-shot code generation

**CodeEvolve (2026)** combines runtime-guided target selection, evolutionary search/MCTS, build validation, unit tests, performance evaluation and refinement. It reports strong improvements on real optimization targets and substantially more valid candidates with the complete search pipeline than weaker variants.

Source: https://arxiv.org/abs/2605.04677

**Magellan (2026)** uses AlphaEvolve-style search to synthesize compact compiler heuristics and reports matching or exceeding expert heuristics on production optimization tasks.

Source: https://arxiv.org/abs/2601.21096

Yardman implication: do not ask an LLM to "optimize the engine" broadly. Give it a small measured decision surface and a frozen evaluator. Candidate examples:

- stream-priority weights;
- cache eviction scoring;
- HLOD thresholds;
- indirect-culling workgroup/layout variants;
- offline world-compiler hot loops;
- packing and quantization choices;
- scheduler allocation heuristics.

The model proposes. Build/tests/benchmarks select.

Research priority: **A+**.

### Independent oracles are mandatory

A July 2026 study found that generating tests after faulty generated code can copy the same mistake into the tests and reduce fault detection compared with independent generation.

Source: https://arxiv.org/abs/2607.05139

SWE-Mutation (ACL 2026) shows that current LLM-generated test suites remain easy for realistic mutants to fool; the reported detection/verification results are not strong enough to treat generated tests as trustworthy ground truth.

Source: https://aclanthology.org/2026.findings-acl.1976/

A separate October 2026 study reports a meaningful fraction of LLM-generated regression tests can become fault-enforcing rather than fault-revealing.

Source: https://arxiv.org/abs/2610.11835

Yardman rule:

1. behavioral requirement/oracle first;
2. implementation second;
3. generated tests may add coverage but do not redefine expected behavior;
4. mutation testing should deliberately inject plausible wrong implementations and measure whether the suite kills them;
5. same-agent code + test agreement is never sufficient evidence.

Research priority: **A+**.

## New graphics research findings

### Mobile Gaussian splatting as a bounded representation, not a world replacement

Recent mobile 3D Gaussian Splatting work focuses on eliminating depth-sorting cost, compressing representation size, and making view-dependent rendering practical on edge devices. Lightweight work also reports very large memory reductions through pruning/quantization.

Sources:
- Mobile-GS: https://arxiv.org/abs/2603.11531
- LFGS: https://doi.org/10.1016/j.cag.2025.104309
- 3DGS compression survey: https://doi.org/10.1111/cgf.70078

Potential Yardman use:

- distant landmark capture;
- skyline/background representation;
- photogrammetry reference layers;
- non-collidable visual proxies for dense static scenes.

Do **not** use splats as the authoritative collision/road/building representation. They are view-dependent visual data, not a substitute for deterministic gameplay geometry.

Research priority: **B** until a portable Godot/Android prototype proves memory, sorting/blending and transparency costs.

### Neural texture compression remains high-upside but portability-limited

NVIDIA's neural material-texture compression demonstrates random-access real-time decoding and much lower bitrates for groups of material textures/mips. Other recent work specifically targets mobile texture loading/memory pressure.

Sources:
- https://research.nvidia.com/labs/rtr/neural_texture_compression/
- https://ojs.aaai.org/index.php/AAAI/article/view/32738

Yardman implication: first test this as an **offline bake/comparison study** against ASTC/ETC2/Basis. A runtime neural decoder is not justified until broad Android portability and shader cost are measured.

Research priority: **B**.

## Updated experiment queue

1. **RDX-003 HZB occlusion feasibility** — only on RenderingDevice/Mobile; conservative visibility oracle required.
2. **RDX-004 cluster/meshlet microbenchmark** — representative buildings + vegetation; compare memory, visible primitives, CPU submission and GPU cost.
3. **RDX-006 evaluator-driven streaming optimization** — freeze real driving traces and metrics before allowing candidate heuristic search.
4. **RDX-009 mutation audit for LLM-generated tests** — inject known retry/streaming defects and verify the suite kills them. This is the direct Yardman adaptation of SWE-Mutation-style evaluation.
5. **RDX-010 Compatibility-vs-Mobile capability matrix** — same device, same route, same content; establish whether a dual RenderingDevice path has enough real-world benefit to maintain.
6. **RDX-011 bounded Gaussian-splat landmark prototype** — one static non-collidable landmark only, with geometry fallback.

## Grading doctrine update

Research grade and production grade are separate.

- **Research grade** answers: did the idea work, remain correct, and produce useful evidence?
- **Production grade** answers: did it win on supported Android hardware under the real Yardman workload with acceptable visual, memory, thermal, battery, package and maintenance cost?

No research result may be called production-ready without both grades.
