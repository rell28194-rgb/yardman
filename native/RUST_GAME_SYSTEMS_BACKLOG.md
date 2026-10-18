# Yardman Rust Game-Systems Backlog

Date: 2026-10-18
Status: research intake; feature behavior is inspiration, implementation and Jamaica-specific content are Yardman-owned.

## Design rule

Do not clone another game's codebase or force Yardman into one game's loop. Extract proven interaction patterns, combine the strongest ones, and make them fit a 1:1 Jamaica where roads, parishes, towns, vehicles, jobs, culture, weather and distance are the actual world model.

The Rust core should make these mechanics composable between the Godot client and an authoritative dedicated server. Godot remains responsible for rendering, scene presentation, UI, input and client-facing effects.

## Social open world

### Seamless public events

Pattern sources: skate. Block Parties, Forza Horizon Arcade/Open, Riders Republic mass events, Motorfest live modes.

Yardman version: `Parish Pulse` events appear in real places and accept players by physical presence instead of a lobby transition. Examples: Half-Way-Tree checkpoint sprint, Palisadoes speed trap chain, Bog Walk hill run, Blue Mountains climb, Montego Bay cruise, Negril sunset meet, Ocho Rios delivery scramble.

Rust systems:
- `interest`: player/event relevance cells and population caps.
- `activity`: event lifecycle, rules, scoring and late join/leave.
- `event_scheduler`: deterministic location/time rotation.
- `snapshot`: leaderboard and activity state replication.
- `rewards`: authoritative payouts and anti-duplicate claims.

### Convoys and crews

Pattern sources: Forza Tour/Convoys, Riders Republic groups, Motorfest crews, skate. crew bounties.

Yardman version: persistent crews plus temporary road convoys. Convoys can move between activities without dissolving. Crew challenges can span parishes, jobs and vehicle classes instead of only races.

Rust systems:
- stable generational member/entity IDs (`slotmap` candidate).
- party/crew state machine.
- shared route target and convoy catch-up metadata.
- presence/interest-aware member replication.
- versioned persistence envelope (`postcard` candidate).

### Social meets and shows

Pattern sources: Horizon Tour/car meets, Motorfest Custom Show, Riders Republic social hubs.

Yardman version: spontaneous and scheduled car/bike meets at actual Jamaican social spaces, garages, beaches, plazas and overlooks. Player voting is bounded and server-authoritative. Meets can turn into cruises, races or photo/replay sessions without scene changes.

## Player-created fun

### Route and challenge drops

Pattern sources: skate. Quick Drops/Throwdowns, Forza EventLab, track builders and community scenarios.

Yardman version: players can author legal-safe gameplay metadata over the real world: start/finish gates, route checkpoints, cones, timing sectors, drift zones, stunt targets and allowed temporary props. Geographic authority is never rewritten by a user challenge.

Rust systems:
- deterministic challenge schema and validation.
- spatial bounds/road attachment checks.
- compact share code / content hash.
- server-side budget and abuse validation.
- replay/ghost compatibility.

### Ghosts, replay and shareable lines

Pattern sources: player ghosts in Riders Republic, skate. Replay Editor, driving-game rival hot laps.

Yardman version: record a compact input/state timeline for races, hill climbs, drift lines and stunt routes. A ghost can be streamed without full live multiplayer authority and can become a challenge seed for friends or global rivals.

Rust systems:
- delta-compressed transform/input timeline.
- deterministic checkpoint scoring.
- content-addressed replay identity.
- interpolation separate from authoritative live snapshots.

## Driving and vehicle play

### Cooperative police heat

Pattern source: NFS Unbound's online chase cooperation.

Yardman version: wanted/response state is an authoritative world system. Nearby crew members may draw attention, block a pursuer or deliberately inherit part of an incident. Rewards depend on actual risk and cannot be farmed by reconnecting.

Rust systems:
- incident graph and participants.
- heat ownership/transfer rules.
- proximity and LOS relevance.
- server rewind only for discrete interaction validation, not full-world rollback.

### Traffic, regional fleets and services

Pattern source: BeamNG regional traffic selection, AI traffic, police events and working taxis.

Yardman version: parish/road-context fleet weighting, route-aware taxis, buses, delivery vehicles, emergency traffic and parked-car populations. Traffic identities are pooled and streamed; high-fidelity behavior is reserved for the player's relevance bubble.

Rust systems:
- persistent spatial indexes (`rstar`, now promoted).
- road graph routing (`petgraph` / `pathfinding` candidates).
- stable pooled entity IDs.
- deterministic regional spawn selection (`rand_chacha` candidate).
- tiered simulation state: dormant, coarse, nearby, physical.

### Race aerodynamics and mechanical depth

Pattern sources: BeamNG slipstreaming/side drafting/bump drafting and deep vehicle configuration.

Yardman version: model the gameplay-relevant aerodynamic wake, tire/brake/thermal and damage state at a budget compatible with Android. Do not attempt BeamNG's full node-beam soft-body simulation on every mobile vehicle. Use layered deformation/damage and higher-cost local detail only where measurable.

## Progression and economy

### Multiple careers instead of one campaign rail

Pattern sources: BeamNG Career Paths, Motorfest thematic Playlists, skate. neighborhood/crew progression.

Yardman paths can include:
- Mechanic / vehicle restoration and tuning.
- Logistics / taxi / delivery / freight.
- Legal motorsport / time attack / hill climb / drag.
- Street scene / meets / drift / underground races.
- Off-road / trail / rural work.
- Exploration / discovery / photography.
- Service / emergency-response activity where appropriate.

Progression should reward actual play patterns rather than force every player through the same event sequence.

### Endless local work

Use parameterized bounties/jobs after authored content is exhausted: vehicle recovery, route delivery, passenger trip, mechanic diagnosis, courier chain, timed drive, clean-driving challenge, photo target, discovery route, convoy objective. Seed generation must be deterministic and validated against available roads/locations.

## Multiplayer architecture required

- Authoritative dedicated Rust simulation.
- Cell-based interest management shared with world streaming.
- Unreliable high-rate state channel plus reliable control/economy/activity channels.
- Local player and controlled-vehicle prediction/reconciliation.
- Snapshot interpolation for remote entities.
- Bandwidth priority accumulation so distant low-priority actors still eventually refresh.
- Lag compensation only for interactions that require it.
- Session migration/reconnect semantics designed explicitly; do not hide disconnects with duplicated rewards/state.
- Server persistence outside the frame/tick critical path.

Transport candidates remain a bake-off: `renet` for game-oriented message channels versus `quinn` for QUIC streams/datagrams and service/control traffic. Do not choose from popularity alone.

## Rust ecosystem lanes

Production-proven now:
- `godot` / gdext 0.5.5 for Godot 4.7 adapter.
- `rstar` 0.13 for persistent mostly-static 2D relevance indexes after Yardman benchmark + Android gate.

Evaluate next:
- `rkyv`: static zero-copy world packs.
- `postcard`: stable versioned control/persistence envelopes.
- `bitcode`: ephemeral same-version snapshot batches only.
- `lz4_flex` and `zstd`: actual tile/world payload compression bake-off.
- `petgraph` / `pathfinding`: road and AI route workloads.
- `slotmap`: authoritative dynamic entity/session IDs.
- `bytes`: server/network buffer ownership.
- `tokio`: dedicated server/service async runtime.
- `renet` / `quinn`: real-time transport bake-off.
- `redb`: embedded durable state for tools/local servers.
- `sqlx`: production service persistence when an external database is warranted.
- `tracing` + `metrics`: server and streaming observability.
- `proptest`: protocol/pack parser invariants.
- `loom`: concurrency model checking for shared-state primitives.
- `parry3d`: selected dedicated-server geometry queries, not duplicate client physics.
- `kiddo`: compare against rstar for nearest-neighbor-heavy immutable datasets.
- `smallvec` / `bitvec`: hot-path allocation and replication-mask optimization after profiling.

## Acceptance rule

A mechanic graduates from this backlog only when it has: a Jamaica-specific design, an authority model, streaming/relevance behavior, persistence rules, reconnect/failure behavior, abuse/duplication safeguards, Android budget, tests, and a measurable reason to exist. A crate graduates only when its representative workload beats the simpler implementation and the Android arm64 gate remains green.
