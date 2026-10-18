# Yardman Rust Ecosystem Intake

Date: 2026-10-18
Scope: shared Rust core, Godot 4.7.2 adapter, future authoritative server, Android arm64

## Rule

Yardman does not add a crate because it is fashionable. A crate must remove measurable CPU time, memory traffic, bandwidth, implementation risk, or duplicated systems. Client-critical additions must keep Android arm64 green. Server-only crates must stay out of the mobile dependency graph unless there is a demonstrated client use.

Game mechanics and networking behavior may be inspired by other games and open technical literature, but Yardman owns its implementation and data. We do not need another game's proprietary source, assets, or protocol to reproduce useful behavior.

## Measured decisions already made

| Candidate | Version | Yardman result | Decision |
| --- | ---: | --- | --- |
| `rstar` | 0.13.0 | Persistent R-tree cut the hosted 131,072-point relevance workload from ~9.23 ms to ~0.49 ms after one-time bulk construction; deterministic ordering retained | **Promoted** into `yardman_core`; HLOD production bridge parity-gated |
| `petgraph` | 0.8.x | Matched Yardman routing results but the purpose-built router was ~1.82× faster on the reused route workload; `petgraph` only won construction time | **Dev-only oracle**; do not ship on Android for routing |
| `postcard` | 1.1.3 | Compact/stable candidate for control messages and persistence deltas | Dev-only until protocol exists |
| `bitcode` | 0.6.9 | Extremely fast/compact in the hosted snapshot bake-off | Dev-only; ephemeral same-version snapshots only, never authoritative long-lived world/save format |
| `lz4_flex` | 0.14.0 | Fast pure-Rust transient compression candidate | Dev-only; real building packs are already small enough that format churn is not justified yet |

The real national building profile changed priorities: the worst compiled YMB1 cell observed in the production Jamaica run was only hundreds of records and tens of KB compressed with low-millisecond Python decode. That does not currently justify redesigning the building format before road/terrain fidelity and Android streaming are further improved.

## High-priority next evaluations

| Candidate | Current researched version | Likely Yardman role | Constraint |
| --- | ---: | --- | --- |
| `rkyv` | 0.8.18 | Zero-copy static world packs: immutable lookup tables, large manifests, server-side prebuilt state | Validation + explicit format/version envelope required; do not replace already-good fixed binary packs merely to use a crate |
| `quinn` | 0.11.12 | QUIC services, encrypted streams/datagrams, bootstrap/session traffic, possibly selected gameplay traffic | Benchmark against a purpose-built real-time transport under mobile loss/jitter before promotion |
| `slotmap` | 1.1.x | Stable generational IDs for server entities, sessions, streamed objects, activities | Strong server fit once entity lifetime becomes dynamic |
| `bytes` | 1.x | Cheaply sliced/ref-counted network and asset buffers | Server/network first; avoid wrapping trivial client allocations |
| `rayon` | 1.x | Parallel offline compilation and dedicated-server batch jobs | Do not blindly run a work-stealing pool on thermally constrained Android gameplay threads |
| `crossbeam` | current stable | Bounded lock-free/low-lock queues for background streaming and server jobs | Add only after contention profiling |
| `dashmap` | current stable | Concurrent service/server caches | Server-first; not a default replacement for ordinary maps |
| `arc-swap` | current stable | Cheap read-mostly config/snapshot publication across threads | Useful for immutable server/world snapshots if profiling supports it |
| `parry3d` | 0.31.x | Dedicated-server LOS/proximity/broad-phase geometry queries | Do not create a second full client physics engine beside Godot |
| `smallvec` | 1.x | Nearby-entity lists, short route adjacency, compact event batches | Apply only after allocation profiles justify it |
| `bitvec` | 1.x | Replication dirty masks, feature/state masks, compact occupancy | Strong fit for protocol/state packing |
| `tracing` + `metrics` | current stable | Server spans, replication timing, bandwidth, queue depth, streaming latency | Server-first; bridge selected counters to Godot diagnostics |
| `geo` | 0.33.1 | Rust-side planar topology, containment, buffers, clipping, validation | Python/PROJ national compiler remains authority until exact parity is proven |
| `geozero` | 0.15.1 | Streaming geospatial conversion without building intermediate object trees | Evaluate for offline/server ingestion, not as a reason to replace working source compilers |
| `flatgeobuf` | 6.0.1 | Indexed binary geospatial interchange, bbox-selective reads, possible tooling/server artifact | Benchmark against Yardman's fixed packs and source workflows; Android client adoption is not assumed |
| `packed_spatial_index_geo` | 0.30.0 | Sidecar indexes for large immutable geospatial datasets / GeoParquet / FlatGeobuf | Interesting for server/tooling archives, not needed for current runtime R-tree path |
| `roaring` | current stable | Large sparse entity/cell visibility or replication sets | Benchmark versus bitsets/hash sets on actual player-interest workloads |
| `proptest` | current stable | Fuzz/property gates for pack parsers, routing invariants, serializer round-trips | Low runtime cost because test-only; good candidate for parser hardening |
| `loom` | current stable | Exhaustive concurrency-model testing for bounded native queues/state publication | Test-only and targeted; not useful until Rust concurrency grows |

## Geospatial position

Yardman already owns deterministic Jamaica production compilers built around Geofabrik OSM, EPSG:3448, and Copernicus GLO-30. Rust geospatial crates are therefore candidates for acceleration, server querying, or future archival formats—not new geographic authority.

`geo`, `geozero`, and FlatGeobuf are most interesting for:

- server-side polygon/region queries,
- offline conversion without JSON object churn,
- indexed archival datasets,
- selective bbox reads from large tooling artifacts,
- future authoritative-server interest regions.

They must reproduce the existing CRS/origin/source hashes and topology exactly before replacing any compiler stage.

## Networking candidates

`renet` remains a serious Godot-independent candidate for a real-time game transport layer because its channel model maps well to reliable control/events plus unreliable transforms. It needs a Yardman loss/jitter/mobile-network bake-off before adoption.

`quinn` 0.11.12 is a strong candidate for QUIC-based services and selected game traffic. It provides encrypted streams and application datagrams and keeps protocol logic separable from the high-level runtime. It is especially attractive for login/session/bootstrap, garages/economy persistence, route/event downloads, replay transfer, and server-to-server traffic. We should not assume QUIC automatically beats a purpose-built real-time UDP path for 20-60 Hz transforms.

`lightyear` is Bevy-specific and should not become a Yardman dependency. Its prediction, interpolation, visibility, bandwidth-priority, lag-compensation, and pre-spawn concepts remain useful design references for `yardman_core`.

`tokio` belongs primarily in future dedicated-server/service executables. Do not embed a general async runtime into the Godot client main loop unless a measured subsystem requires it.

## Feature/mechanic bank enabled by the Rust core

The same core architecture can support seamless nearby-player presence; drop-in/drop-out sessions; crews and convoys; player/vehicle prediction and reconciliation; snapshot interpolation; lag-compensated interactions; server rewind for selected actions; ghost/replay runs; route and stunt-line sharing; spontaneous races; public road events; parish/region activities; proximity voice metadata; shared garages/meets; dynamic jobs; traffic incidents; police/heat state; persistent vehicle ownership/state; leaderboards; time trials; world-event scheduling; interest-managed NPCs/traffic; server-authoritative economy; anti-cheat validation; deterministic activity scoring; and bandwidth-prioritized replication.

Those are feature patterns, not copies of another game's code. They can be composed around Jamaica-specific roads, culture, parishes, vehicles, jobs, events, and social spaces.

## Explicit non-goals

- Do not rewrite Godot UI/editor-facing code into Rust for ideological consistency.
- Do not replace Godot physics/rendering with duplicate Rust engines on the client.
- Do not make a Bevy ECS or Bevy networking stack the hidden second game engine.
- Do not let a crate become a production dependency without tests, Android impact review, and a measurable reason.
- Do not use unstable binary formats for long-lived saves or authoritative world assets without an explicit migration/version envelope.
- Do not replace a small proven custom binary format (`YMR1`, future equivalents) with a general serializer unless measurements show a real benefit.

## Next gates

1. Keep `rstar` as the production spatial index and expand only through parity-gated consumers.
2. Keep the custom Yardman road router as production; retain `petgraph` only as a test/oracle dependency.
3. Prototype `rkyv` only on a genuinely large immutable dataset, not the already-small YMB1 worst cell.
4. Prototype `renet` versus `quinn` under simulated mobile loss/jitter with Yardman-shaped snapshot/control traffic.
5. Evaluate `geo`/`geozero`/FlatGeobuf for offline/server geospatial workloads against the current authoritative compiler outputs.
6. Add property/fuzz tests to native pack parsers before expanding binary world formats.
7. Keep Android arm64 compilation mandatory after each native dependency promotion.