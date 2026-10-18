# Yardman Project-Wide Quality Audit — 2026-10-18

Scope: current Godot production runtime on `codex/world-quality-20261018`. This audit is intentionally critical. It separates things that are structurally sound from areas where the implementation can still produce player-visible instability, loading stalls, false confidence from tests, or unnecessary maintenance cost.

## Executive assessment

Yardman is no longer failing because the project lacks basic systems. The opposite problem is emerging: many individually competent systems now overlap, duplicate policy, and compete for the same frame, I/O, data, and validation budgets. The next quality jump will not come from adding more subsystems. It will come from consolidation, stronger runtime contracts, real-data/on-device validation, and replacing expensive general-purpose runtime formats on the hottest paths.

The project is strongest where behavior is deterministic and explicitly budgeted: road/terrain streaming, shared integration envelopes, geometry slicing, thermal contraction, parish/world-coordinate truth, and the newer retry/recovery logic. It is weakest where ownership is implicit: dozens of autoloads with independent process loops, multiple streaming implementations with similar but not identical failure semantics, duplicated content decode paths, and CI lanes that historically validated structure more strongly than player-visible behavior.

## Findings and required corrections

### 1. Runtime orchestration is too fragmented

`project.godot` currently owns a large number of autoload singletons. Many have independent `_process()` loops, clocks, scene rebinding logic, budgets, and cross-system lookups. This is manageable while systems are isolated, but it becomes a coordination tax as traffic, pedestrians, lighting, weather, jobs, roads, buildings, vegetation, audio, vehicles, and map/location state interact.

Risk: frame-order dependencies become accidental; two systems can both be correct locally and still spike the same frame. Debugging becomes harder because ownership is distributed. Adding one feature often means adding one more always-on runtime.

Correction: do not perform a risky one-shot rewrite. Introduce ownership domains and migrate incrementally. The target domains should be World Streaming, Population, Vehicle/Traffic, Environment/Lighting, Jobs/Persistence, and UI/Location. Each domain should own one scheduler/clock and call bounded child work in a deterministic order. Retain small classes for implementation, but stop making every implementation class an independent root autoload.

Acceptance gate: autoload count decreases without reducing systems; no new gameplay regression; domain schedulers expose timing and queue snapshots; order-sensitive behavior is covered by tests.

### 2. Streaming recovery policy was duplicated and inconsistent

Road/terrain previously treated a failed tile as failed for the rest of the session. Near-building and HLOD paths had a related failure mode where a stationary player could remain beside a failed cell without a forced retry.

Corrections already landed during this audit cycle: bounded exponential retry for road/terrain, a shared retry policy, and shared building/HLOD recovery with forced stationary refresh. These are the correct direction.

Remaining correction: road/terrain should migrate to the same shared retry policy implementation instead of keeping a private copy of backoff constants and release semantics. One policy should define attempt counting, retry deadlines, stale-failure cleanup, success reset, and diagnostics.

Acceptance gate: one retry policy implementation; road, terrain, near buildings, and HLOD all report the same diagnostic schema; deterministic tests cover first failure, repeated failure, success reset, stale unload, and stationary retry.

### 3. Runtime building decode is still too expensive and too general-purpose

Near-building and HLOD readers both read a YMB1 indexed cell, gzip-decompress a payload, convert bytes to UTF-8, and JSON-parse an array before geometry work begins. This happens off the main thread, which is better than synchronous parsing, but the cost still consumes CPU, allocations, memory bandwidth, and thread time on Android. The same semantic data is decoded by two runtime paths.

Risk: entering dense areas can become I/O + decompression + allocation bound before geometry budgets even apply. JSON is also a weak runtime contract for a production mobile streaming format because numeric arrays allocate heavily and type validation happens late.

Correction order:
1. Benchmark real representative cells: rural, suburban, Kingston-dense, Montego Bay-dense, worst-case cell.
2. Record compressed bytes, decompressed bytes, parse time, allocations if measurable, records/cell, vertices generated, and total time to first visible mesh.
3. Introduce a versioned packed binary cell payload while preserving the outer indexed tile container and exact source/provenance semantics.
4. Decode directly into compact typed arrays/records; avoid UTF-8/JSON on the hot path.
5. Keep a compatibility reader only for transition/testing; production-generated content should move to the packed version once equivalence is proven.

Acceptance gate: exact record equivalence against current content, deterministic hashes, lower decode latency on representative cells, bounded memory, Android arm64 compile/runtime validation, and no geometry/provenance changes.

### 4. Tests are strong structurally but still underweight real player-visible integration

The world-quality gate now catches parser/runtime log dirt, terrain seams, routing, stream budgets, building HLOD, population behavior, and several render captures. That is good. However, deterministic fixtures cannot prove that the full production island, actual private vehicle assets, real Android GPU/driver behavior, and long-session memory churn behave the same way.

Risk: the project can be “green” while the owner still experiences slow loading, visual holes, audio imbalance, or device-specific hitches.

Correction: maintain three distinct gates and never confuse them:
- Contract gate: deterministic unit/fixture tests.
- Production-data gate: sample real Jamaica tiles/cells/assets from every major density regime and parish class.
- Device gate: actual Android build on target-class hardware with frame-time, memory, thermals, loading latency, and long-drive evidence.

Promotion requires all applicable gates. A structural pass is not visual acceptance; a load pass is not runtime acceptance.

### 5. The project still has multiple data and implementation eras alive at once

Godot is the production runtime, but legacy `Assets/`, C# compiler/tests, and historical pipelines remain in the repository. They are useful as reference and contract evidence, but historically their CI ran on every push and could make legacy validation look more authoritative than current production validation.

Correction already landed: legacy core CI is scoped to its actual inputs. Continue this policy. Legacy code should remain read-only/reference unless a production Godot dependency explicitly requires it.

Acceptance gate: no Godot-only change waits on unrelated legacy regeneration; no legacy output is treated as proof of production runtime behavior.

### 6. Shared frame budgets exist, but ownership must become more explicit

The render runtime correctly caps aggregate streaming integration rather than letting roads, terrain, buildings, HLOD, and roadside work independently spend their maximum. This is a major improvement. The remaining problem is that additional runtimes outside that envelope can still produce coincident work: population updates, traffic, pedestrians, lighting, weather, reflections, audio, jobs, and UI/location systems.

Correction: extend the concept from “streaming budget” to a project-wide frame-work budget. Not every system needs microsecond slicing, but expensive work should register into named classes: critical gameplay, stream integration, population simulation, visual maintenance, background housekeeping. Background classes should stagger by frame/phase and contract under thermal pressure.

Acceptance gate: 60-FPS target frames retain headroom for physics/gameplay; no quality tier authorizes a hitch; thermal pressure reduces optional work before core world correctness.

### 7. Visual quality and geographic truth need separate acceptance dimensions

Yardman can be geographically correct but visually weak, or visually attractive but geographically wrong. A single “world quality” label hides that distinction.

Correction: maintain two explicit grades for each representative area:
- Geographic truth: alignment, scale, road topology, terrain/coast relation, parish/location correctness, building footprint registration.
- Presentation fidelity: materials, silhouettes, vegetation zoning, lighting, atmospheric depth, road edge treatment, building variety, visual continuity, pop-in.

Do not trade one silently for the other. The full-island 1:1 doctrine remains non-negotiable.

### 8. Vehicle production and world production must remain isolated at the branch and acceptance level

World defects are not vehicle failures and vehicle defects are not map failures. Crown007 remains the protected accepted vehicle reference. Private vehicle quality requires its own provenance, geometry, material, rig, hook, lifecycle, and control gates.

Correction: continue narrow cherry-pickable vehicle commits and separate world-quality commits. Only integrate after both sides pass their own gates. Do not use a map/world branch to repair vehicle presentation or vice versa.

### 9. Observability is still too reactive

Several defects were discovered by reading implementation after owner-visible symptoms. Runtime systems expose some snapshots, but there is no single lightweight health picture covering stream queues, failed/retrying cells, loaded counts, integration allocation, population counts, frame timing, memory trend, and thermal stage.

Correction: build one diagnostic snapshot interface that aggregates existing counters without adding heavy per-frame instrumentation. It should be available to tests and optional developer HUD/log capture, not constantly spam logs in production.

Acceptance gate: one captured snapshot can answer “what is loading, what failed, what is waiting, what budget is active, what population is resident, and what thermal stage is applied?”

### 10. Content quality needs cohort-based promotion, not bulk exposure

This applies to vehicles, buildings, road presentation, and recovered assets. The project has enough recovered/source material that quantity can outrun quality.

Correction: keep representative cohorts small until each pipeline proves source identity, provenance, clean import, geometry correctness, materials, lifecycle, Android cost, and visual acceptance. Once a cohort passes consistently, scale that validated pipeline in batches. Do not promote because an asset loads.

## Execution order

P0 — Preserve correctness and eliminate permanent holes:
- Keep shared log policy enforced.
- Keep road/terrain bounded retry green.
- Keep near-building/HLOD stationary recovery green.
- Migrate all stream families to one retry policy implementation and one diagnostic schema.

P1 — Attack loading latency with evidence:
- Benchmark current YMB1 gzip+JSON building decode on representative real cells.
- Measure road JSON tile decode similarly.
- Replace the highest-cost general-purpose hot-path format with a versioned packed format only after equivalence evidence exists.
- Keep geometry creation budgeted on the main thread; do not move unsafe Godot object creation into worker threads.

P2 — Reduce orchestration overhead:
- Inventory all autoload `_process()`/`_physics_process()` cadences and scene lookups.
- Group them into ownership domains.
- Migrate low-risk housekeeping systems first, then population/environment groups.
- Preserve exact behavior while reducing independent clocks and root-level singletons.

P3 — Raise integration confidence:
- Add representative production-data fixtures from multiple parishes/density regimes.
- Add long-drive soak evidence with queue counts, memory, node counts, retry counters, and frame-time percentiles.
- Add target-class Android device evidence before owner-build promotion.

P4 — Visual/world fidelity push:
- Separate geographic truth grades from presentation grades.
- Fix the worst visible continuity defects first: loading/pop-in, road/terrain transitions, building repetition, vegetation zoning, lighting/material consistency.
- Only after stability and streaming headroom are proven should density/detail expand aggressively.

## Current project grade

Architecture/correctness: B. The foundations are substantially better than the owner-visible instability suggests, but ownership is too distributed.

Streaming design: B+. Budgets, threading, floating-origin/world coordinates, and recent retry work are strong. Runtime text decode and duplicated policy remain weaknesses.

Android readiness: B-. Android is first-class in intent and native compilation is validated, but production-data/device evidence is still not broad enough to call the island runtime hardened.

Visual/world fidelity: C+/B- depending on area. The systems exist, but consistency and density across the whole island are not yet at the target presentation bar.

Validation maturity: B. CI is much stronger now, but must continue shifting from synthetic correctness toward production-data and on-device evidence.

Project-wide trajectory: positive, provided the next phase prioritizes consolidation and measured hot-path work over adding more independent runtimes or exposing more ungraded content.
