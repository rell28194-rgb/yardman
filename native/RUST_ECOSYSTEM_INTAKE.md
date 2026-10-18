# Yardman Rust Ecosystem Intake

Date: 2026-10-18
Scope: shared Rust core, Godot 4.7.2 adapter, future authoritative server, Android arm64

## Rule

Yardman does not add a crate because it is fashionable. A crate must remove measurable CPU time, memory traffic, bandwidth, implementation risk, or duplicated systems. Client-critical additions must keep Android arm64 green. Server-only crates must stay out of the mobile dependency graph unless there is a demonstrated client use.

Game mechanics and networking behavior may be inspired by other games and open technical literature, but Yardman owns its implementation and data. We do not need another game's proprietary source, assets, or protocol to reproduce useful behavior.

## Bake off now

| Candidate | Version researched | Yardman use | Current state |
| --- | ---: | --- | --- |
| `postcard` | 1.1.3 | Stable compact wire format for control messages, persistence deltas, and versioned network envelopes | Dev-only benchmark |
| `bitcode` | 0.6.9 | Very compact/high-throughput ephemeral snapshots where both endpoints run the same Yardman protocol version | Dev-only benchmark; never use as a long-term save/world format because major-version format stability is a non-goal |
| `lz4_flex` | 0.14.0 | Pure-Rust fast compression/decompression for streamed tile payloads and transient snapshot batches | Dev-only benchmark |
| `rstar` | 0.13.0 | Bulk-loaded R-tree for many-query/few-update relevance, POI, traffic, building, and network-interest lookups | Dev-only benchmark |

`native/yardman_core/examples/ecosystem_bakeoff.rs` compares these on a Yardman-shaped workload before any of them become production dependencies.

## High-priority next evaluations

| Candidate | Likely Yardman role | Constraint |
| --- | --- | --- |
| `rkyv` 0.8.x | Zero-copy static world packs: manifests, immutable road/building metadata, prebuilt lookup tables | Validate versioning/migration story and aligned-file access before adoption |
| `petgraph` 0.8.x | National road graph, route search, connected-components QA, AI routing support | Compare with the existing deterministic graph representation before replacing anything |
| `slotmap` 1.1.x | Stable generational IDs for server entities, sessions, streamed objects, jobs, activities | Good fit when object lifetime becomes dynamic and stale-ID safety matters |
| `bytes` 1.x | Cheaply sliced/ref-counted network and asset buffers | Prefer in server/network layers; do not wrap every small client allocation |
| `rayon` 1.x | Parallel offline compilation and dedicated-server batch work | Do not blindly use a work-stealing pool on thermally constrained Android gameplay threads |
| `crossbeam` / `dashmap` | Bounded queues and concurrent caches | Add only after profiling proves a lock/contention problem |
| `parry3d` 0.31.x | Dedicated-server geometric queries, broad-phase checks, LOS/proximity, simplified authoritative collision tests | Do not create a second full client physics engine beside Godot |
| `smallvec` 1.x | Hot small collections: nearby entities, short route adjacency, compact event lists | Apply only after allocation profiles justify it |
| `bitvec` 1.x | Replication dirty masks, feature/state masks, compact occupancy maps | Strong fit for protocol/state packing |
| `tracing` + `metrics` | Server spans, replication timing, bandwidth, queue depth, streaming latency | Server-first; bridge only selected counters back into Godot diagnostics |
| `geo` 0.33.x | Offline geographic operations and validation in Rust | Existing Python/PROJ pipeline remains authority until parity is proven |

## Networking candidates

`renet` 2.0 is a serious Godot-independent candidate for the real-time game transport layer because it already exposes reliable-ordered, reliable-unordered, and unreliable channels plus fragmentation, connection management, authentication, and encryption. It needs a Yardman loss/jitter/mobile-network bake-off before adoption.

`quinn` 0.11.x is a strong candidate for QUIC-based services and possibly selected game traffic: encrypted streams, datagrams, congestion control, and a deterministic protocol core. It is especially attractive for session/bootstrap/control traffic and service-to-service communication. We should not assume QUIC automatically beats a purpose-built game UDP layer for high-rate transforms; benchmark both.

`lightyear` 0.30.x is Bevy-specific, so it should not become a direct Yardman dependency. Its feature set is still valuable as a design reference: client prediction, rollback, snapshot interpolation, input delay, network visibility, pre-spawning, bandwidth caps with priority accumulation, and lag compensation. Those behaviors belong in `yardman_core` without importing Bevy.

`tokio` belongs primarily in the future dedicated server and service executables. Do not embed a general async runtime into the Godot client main loop unless a measured subsystem requires it.

## Feature/mechanic bank enabled by the Rust core

The same core architecture can support seamless nearby-player presence; drop-in/drop-out sessions; crews and convoys; player/vehicle prediction and reconciliation; snapshot interpolation; lag-compensated interactions; server rewind for selected actions; ghost/replay runs; route and stunt-line sharing; spontaneous races; public road events; parish/region activities; proximity voice metadata; shared garages/meets; dynamic jobs; traffic incidents; police/heat state; persistent vehicle ownership/state; leaderboards; time trials; world-event scheduling; interest-managed NPCs/traffic; server-authoritative economy; anti-cheat validation; deterministic activity scoring; and bandwidth-prioritized replication.

Those are feature patterns, not copies of another game's code. They can be composed around Jamaica-specific roads, culture, parishes, vehicles, jobs, events, and social spaces.

## Explicit non-goals

- Do not rewrite Godot UI/editor-facing code into Rust for ideological consistency.
- Do not replace Godot physics/rendering with duplicate Rust engines on the client.
- Do not make a Bevy ECS or Bevy networking stack the hidden second game engine.
- Do not let a crate become a production dependency without tests, Android impact review, and a measurable reason.
- Do not use unstable binary formats for long-lived saves or authoritative world assets without an explicit migration/version envelope.

## Next gates

1. Run the current data-path/spatial bake-off and record sizes and timings.
2. Promote only winners into normal dependencies.
3. Prototype `rkyv` static world-pack access separately from network serialization.
4. Prototype `renet` versus `quinn` under simulated mobile loss/jitter with Yardman snapshot traffic.
5. Move the first production streamer selection path to Rust behind a GDScript fallback and parity test.
6. Keep Android arm64 compilation mandatory after each native dependency promotion.
