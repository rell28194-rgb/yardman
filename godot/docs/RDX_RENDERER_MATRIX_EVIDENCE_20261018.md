# RDX-010 Renderer Capability Matrix Evidence — 2026-10-18

Status: high-confidence capability/fallback contract. This is not physical Android performance evidence.

## Provenance

- R&D branch: `codex/rdx-renderer-matrix-001`
- Production-derived base: `codex/world-quality-20261018` at `003fda123b7c8cf901379e7a135a16017820deec`
- Evaluated commit: `fcd98078bfd1f7d5aaf471010549745e17682cd0`
- Cleanup head after the evaluated commit: `015aa70e227d463acedc4bd483f43a6f72b581ee`
- Workflow: `Yardman RDX Renderer Matrix`
- Run: `39181589787`
- Compatibility job: `117835289771`
- Mobile/Vulkan job: `117835289965`
- Godot: 4.7.2 stable

## Frozen source contract

Before editor import, CI verifies the checked-in project configuration still declares:

- desktop/headless `gl_compatibility`
- mobile `mobile`
- ETC2/ASTC Android texture import enabled

The runtime oracle then validates the renderer Godot actually started, rather than trusting the project setting alone.

## Compatibility result

Actual backend: OpenGL Compatibility on Mesa llvmpipe.

`YARDMAN_RDX_RENDERER_MATRIX label=compatibility method=gl_compatibility driver=opengl3 family=gles rd=0 shaders=7 luma=0.046198 lit_samples=13 road=road:safe water=water:safe terrain=terrain:safe result=PASS`

The production quality/material policy resolved the active renderer to `gles`, exposed no RenderingDevice, selected the safe road/water/terrain shader family, rendered the representative seven-shader probe, passed runtime material switching, and passed adaptive quality/thermal/frame-pacing policy tests.

## Mobile/Vulkan result

Actual backend: Vulkan Forward Mobile on Mesa llvmpipe.

`YARDMAN_RDX_RENDERER_MATRIX label=mobile method=mobile driver=vulkan family=vulkan_mobile rd=1 shaders=7 luma=0.055795 lit_samples=14 road=road:high water=water:high terrain=terrain:high result=PASS`

The production quality/material policy resolved the active renderer to `vulkan_mobile`, exposed a RenderingDevice, selected the high road/water/terrain shader family for Balanced quality, rendered the representative seven-shader probe, passed runtime material switching, and passed adaptive quality/thermal/frame-pacing policy tests.

Both backends also passed:

- `YARDMAN_MATERIAL_VARIANTS_TEST PASS families=3 runtime_water_switch=1 road_terrain_switch=1`
- `YARDMAN_RENDER_QUALITY_TEST PASS renderer_policy=1 adaptive=1 thermal=1 frame_pacing=1 auto_pressure=1 material_ladder=1 shadow_distribution=1 refresh_cadence=1 gpu_headroom=1 invalid_preferences=1 resume=1`

## Oracle challenge checks

For both backends, the workflow deliberately supplies three false expectations and requires the evaluator to reject them:

1. wrong rendering method
2. wrong normalized renderer family
3. wrong RenderingDevice availability

All six negative controls were rejected as intended. This prevents a trivially permissive renderer oracle from passing the matrix.

## Grade

Research/correctness grade: **A / 96 out of 100 confidence** for the renderer capability, material-selection and fallback contract.

Production-performance grade: **withheld**. The hosted jobs used llvmpipe. Their frame time is not representative of a phone. The logs also report `cannot connect to daemon at tcp:5037`, so no physical Android device was attached.

## Remaining promotion gate

Run the same route/content/quality comparison on supported physical Android hardware and record at minimum:

- device/GPU/driver
- cold boot and shader warm-up behavior
- p50/p95/p99 CPU and GPU frame time
- RAM and graphics-memory pressure where observable
- thermal trend and throttling over a sustained drive
- battery/power trend where available
- visual differences between Mobile/Vulkan and the Compatibility fallback
- crash/device-lost/shader-compile failures

Until that device evidence exists, RDX-010 proves that Yardman's two renderer paths and production material policy are internally coherent; it does not prove that Mobile/Vulkan is faster or thermally superior on Android.
