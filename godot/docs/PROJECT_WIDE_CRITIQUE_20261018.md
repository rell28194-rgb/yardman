# Yardman project-wide engineering critique

Date: 2026-10-18
Branch reviewed: `codex/world-quality-20261018`
Production target: Godot 4.7.2, full-island Jamaica, Android first-class

This is an execution document, not a restart plan. The full-island target, 1:1 horizontal scale, 14-parish runtime and Godot production direction remain unchanged.

## Executive assessment

Yardman is no longer blocked by a lack of systems. It has the opposite problem: many individually competent systems now need stronger shared contracts. Streaming budgets, thermal contraction, national graph identity, HLOD, traffic/pedestrian layers, rendering policy and Android-native work are real strengths. The next major quality gain will come from reducing duplicated orchestration, eliminating text-heavy runtime data paths, strengthening recovery behavior and validating the integrated game on representative island data and real Android hardware.

The project should stop equating subsystem green tests with release readiness. Source-only fixture tests are necessary and fast, but the release gate must additionally prove real content, real private vehicle integration, sustained movement through streamed Jamaica and on-device thermal/frame-time behavior.

## Defects fixed during this audit

1. **Dirty Godot output could pass CI.** A route fallback string containing a NUL produced Unicode parser warnings even though the workflow was green. The source defect was removed and `godot/tools/check_godot_log.py` now centralizes failure policy for script errors, parse errors, Unicode parsing errors and Godot `ERROR:` lines. World-quality and Rust/Godot smoke both self-test and consume the same guard.

2. **Road/terrain tile failure was session-poisoning.** `road_streamer.gd` stored failed keys indefinitely while `_refresh_tiles()` refused to enqueue failed keys. Terrain inherits the same scheduler. A transient thread/read failure could therefore leave a hole for the remainder of the session. The base scheduler now converts failures to deterministic exponential retry state (1s, 2s, 4s ... capped at 30s), retries even if the player remains in the same tile, drops stale off-window failures and clears retry history after successful residency. `stream_retry_test.gd` gates the policy.

3. **Legacy core CI ran on every push.** `.github/workflows/core.yml` installed Python/.NET and regenerated legacy `Assets/StreamingAssets` for Godot-only changes. It is now path-scoped to the legacy compiler/core inputs while remaining manually dispatchable.

## Priority 0 — preserve runtime correctness under streaming failure

### Near buildings and HLOD still have weaker retry semantics

`JamaicaBuildingStreamer` and `YardmanBuildingHLODRuntime` remove a failed cell only after that cell leaves the wanted set. If the player remains stationary beside a failed cell, that cell can remain absent indefinitely. Road/terrain now recover in-place; buildings should follow the same contract.

**Remedy:** extract one reusable stream-failure/backoff policy and use it in road, terrain, near buildings and HLOD. Do not copy four retry implementations. Every stream job should expose: stable content key, attempt count, retry deadline, failure class, cancellation state and last error category. Permanent schema/corruption failures should back off aggressively and surface diagnostics; transient I/O/thread failures should retry quickly.

## Priority 1 — replace independent thread ownership with a global streaming admission policy

Roads, terrain, near buildings and HLOD each own queues and create `Thread.new()` workers. Cool-state budgets can allow multiple workers per subsystem, while terrain also owns an overview thread. The project already solved aggregate **main-thread geometry integration** through `RenderRuntime.stream_integration_budget_for()`, but it does not yet have an equivalent aggregate I/O/worker admission controller.

This matters on Android because several independent readers/decompressors/parsers can wake simultaneously, compete for little cores, increase memory bandwidth pressure and make loading less predictable even when main-thread mesh work is correctly budgeted.

**Remedy:** move stream reads/decodes to a shared job scheduler or Godot worker pool with a small measured global concurrency limit. Prioritize by gameplay need rather than subsystem ownership: immediate terrain/coast and road residency first, near buildings next, then HLOD/background overview. Add age-based promotion so a distant job cannot starve forever. Record queued, running, cancelled and completed job counts by subsystem. Tune the global slot count on actual Android hardware; do not assume more threads mean faster loading.

## Priority 1 — remove JSON from hot national content paths

The terrain path is already compact float32 binary. Roads and buildings are not:

- Road tiles call `JSON.parse_string(FileAccess.get_file_as_string(path))` at runtime.
- Building `YMB1` cells have a binary tile index, but each cell is GZIP-compressed UTF-8 JSON and becomes large Variant/Array trees before geometry preparation.
- Building HLOD independently repeats the same GZIP + UTF-8 + JSON decode.

That architecture creates avoidable allocation, UTF-8 conversion and parser overhead exactly when the player is crossing a streaming boundary.

**Remedy:** benchmark before changing formats. Commit representative real-schema fixtures, then compare current GZIP+JSON against a typed binary v2 pack with independently addressable cells. Preserve deterministic IDs and migration/version headers. Prefer one decode that can feed both near and HLOD consumers rather than parsing the same cell twice. Candidates such as postcard/LZ4 or a purpose-built fixed layout should remain candidates until measured on Yardman-shaped data and Android arm64. The route-pack rollout is the model: deterministic compiler, golden fixture, source fallback/parity, native adapter, Android compile, then runtime adoption.

## Priority 1 — reduce singleton/autoload fragmentation

`project.godot` currently registers **46 autoload singletons**. Many are valid isolated features, but the count is now an architectural signal: frame ordering, scene rebinding, shared state, diagnostics and thermal policy increasingly cross singleton boundaries. `RenderRuntime` already has to run at a deliberate process priority so its shared stream cap wins over HLOD's local profile.

**Remedy:** freeze autoload growth temporarily. Consolidate by ownership, not by deleting features. A practical target is a small set of service roots with child modules:

- World streaming/render coordination
- Population/traffic/pedestrian simulation
- Vehicle runtime/garage/presentation
- Environment/weather/audio
- Gameplay/jobs/persistence
- UI/location/parish services

Migration should be incremental. Existing public groups/signals can remain compatibility adapters while process ownership and shared budgets move under the service root. The objective is fewer independent `_process()` owners and a single place to observe each domain, not a monolithic script.

## Priority 1 — keep one production authority

Godot is the production runtime, but the repository still carries a legacy C#/Unity-era core/compiler and committed `Assets/StreamingAssets`. Keeping recovery/reference code is reasonable; letting it look like an equal runtime authority is not. Before this audit, its workflow ran on every push, reinforcing that ambiguity.

**Remedy:** label legacy contracts explicitly as reference/compatibility. Any rule still required by Godot should be moved to the Godot/Rust/Python production toolchain or generated from one schema. Avoid manually maintaining equivalent constants and validation semantics in C#, Python, GDScript and Rust. CI should make production Godot gates the default signal and legacy compatibility gates conditional on relevant changes.

## Priority 1 — add a real-content and real-device release ladder

The world-quality suite intentionally uses deterministic local fixtures and does not require island downloads, private vehicles or the Android SDK. That makes it fast and reliable, but it cannot prove real content pressure or release behavior. Android arm64 native compilation proves ABI/build compatibility, not runtime performance.

**Remedy:** maintain three validation tiers:

1. Fast source/fixture gate on every relevant change.
2. Full-content integration gate using representative or complete compiled Jamaica artifacts, including actual road/building/terrain packs and release vehicle integration.
3. Physical Android soak gate that drives/streams continuously and records frame CPU/GPU time, p95/p99 hitch duration, memory/RSS, loaded node/resource counts, I/O latency, thermal stage and crash/log cleanliness.

A release candidate should fail if sustained driving crosses a fixed hitch/memory/thermal envelope even if every subsystem unit test passes.

## Priority 2 — separate shared streaming mechanics from road semantics

`JamaicaTerrainStreamer` inherits `road_streamer.gd`. This successfully reuses queue/job/residency machinery, and the retry fix benefits both immediately, but the abstraction leaks road-specific fields and assumptions into terrain. For example, runtime budgeting can write road-oriented fields such as segment limits onto terrain even though terrain builds rows/triangles.

**Remedy:** extract a narrow `StreamTileScheduler`/composition object for wanted-set calculation, queue priority, retry/cancellation and job lifecycle. Road and terrain then own their own decode/build state. Do this after the current retry policy is stable; avoid a large rewrite before behavior is covered.

## Priority 2 — move more geometry preparation off the main thread, not Godot rendering itself

Road, terrain and building mesh assembly is time-budgeted, which is good, but substantial array preparation and collision-face construction still happens on the main thread. The aggregate envelope prevents runaway spikes but does not make the work free.

**Remedy:** precompute more immutable geometry offline or produce packed vertex/index/collision buffers in workers/Rust where safe. Keep Resource/scene-tree mutation and final rendering-server uploads on the main thread. For collision, stream simplified gameplay meshes independently from visual detail. Measure upload cost separately from decode/build cost so optimization targets the actual stall.

## Priority 2 — production routing fallback needs explicit observability

The Rust route pack now has a deterministic GDScript fallback. That is excellent for source-only CI and graceful degradation. The risk is that a production build could silently run whole-graph GDScript routing if the native extension/pack fails to activate, turning a correctness fallback into a performance regression.

**Remedy:** expose route backend in runtime diagnostics and release telemetry. Android release validation should explicitly assert `rust-route-pack` when native routing is expected. Keep the fallback for debugging/recovery, but do not silently accept it as equivalent production performance. If native routing is unavailable, rate-limit route requests and surface the condition clearly.

## Priority 2 — integrate vehicle and world lanes before declaring a release candidate

The world bootstrap still uses a generic `CharacterBody3D`/box physics anchor while private vehicle production is developed on separate branches and runtime layers. Lane isolation is correct during parallel development, but world tests therefore do not certify production vehicle wheel/collider/seat/exit behavior against real streamed terrain and roads.

**Remedy:** keep the branches isolated during production, then create an explicit release-integration branch/gate. The integration gate must use an accepted vehicle cohort, run enter/drive/park/exit/re-enter/reset across streamed tiles, verify road-surface and terrain collision, and preserve Crown007's accepted reference state. Map failures and vehicle-asset failures should remain separately attributable.

## Priority 2 — strengthen observability before further optimization

Yardman now has several good budget systems, but optimization decisions still require too much code inspection. A runtime snapshot should make the active bottleneck obvious.

**Remedy:** one diagnostics surface should report at least: current parish/world position, stream backend versions, wanted/queued/inflight/failed counts per streamer, retry counts, global I/O slots, decode time, geometry integration time, loaded cells/tiles, HLOD backend, route backend, traffic/pedestrian counts, memory, render CPU/GPU time, thermal stage and last significant errors. Capture it automatically in soak artifacts.

## Priority 3 — CI should be fast by relevance, strict by evidence

The shared Godot log guard and legacy core path scoping are steps in the right direction. Continue auditing workflows for duplicated engine downloads, overlapping runs and broad triggers. Reusable setup/caching can reduce queue time, but never trade away deterministic validation. Cancel superseded branch runs where safe and preserve exact-head artifacts for accepted milestones.

## Priority 3 — visual quality must graduate from isolated correctness to scene-level review

Yardman has render gates for terrain zoning, shoreline water and asphalt response. Those protect specific regressions. AAA-like presentation, however, is an integrated result: exposure, material scale, shadow stability, atmospheric depth, vegetation density, road edge treatment, traffic composition, animation and camera behavior interact in one frame.

**Remedy:** after streaming stability, build a small fixed Jamaica visual cohort (urban, coastal, rural, mountain, wet/night) with deterministic camera positions. Store captures and objective metrics where useful, but retain human critical review for composition/material plausibility. Do not chase screenshot polish by increasing residency or shader cost beyond Android budgets.

## What should not be thrown away

- Full-island tiled doctrine and deterministic stable IDs.
- Aggregate mobile streaming integration envelope and thermal ladder.
- Roadside deferred scheduler rather than same-frame fan-out.
- HLOD with Rust spatial-index parity and GDScript fallback.
- Binary terrain samples and registered coast/terrain coordinate checks.
- Route-pack SHA/count validation, source fallback and Android arm64 gate.
- Narrow regression tests for previously observed player-visible defects.
- Separate vehicle-production and map/world lanes until release integration.

## Execution order

1. Finish retry consistency for near buildings/HLOD and add failure/recovery counters.
2. Instrument global streaming I/O concurrency and decode/integration timings on Android.
3. Replace independent stream threads with one measured admission scheduler.
4. Commit representative road/building pack fixtures and run the building/road binary-codec bake-off; migrate only if measured.
5. Consolidate autoload ownership incrementally while preserving public signals/groups.
6. Establish full-content + physical Android soak as the release gate, then integrate the accepted vehicle cohort with the world lane.

The project does not need a restart, engine switch, reduced Jamaica scope or feature purge. It needs fewer independent owners for the same resources, less runtime text decoding, stronger recovery semantics and evidence that the integrated island behaves well under sustained Android load.
