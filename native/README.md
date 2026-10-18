# Yardman native systems decision

Yardman-owned high-throughput systems use **Rust** as the primary native language.

This is not a whole-project rewrite. Godot 4.7.2 remains the engine, and GDScript remains the thin engine-facing layer for scene lifecycle, UI, signals, editor integration, and other orchestration where native code would add complexity without measurable value.

## Why Rust

The first controlled GDExtension bake-off proved both C++ and Rust can load into the canonical Godot 4.7.2 runtime and reproduce the same 120,000-point spatial workload exactly. The Rust lane also gives Yardman a clean path to share the same engine-independent code with a future authoritative dedicated server.

The C++ experiment remains useful evidence and a fallback for future Godot engine-source/module modifications, but Yardman game/backend systems should not grow two competing native stacks.

## Ownership boundary

`yardman_core` is pure Rust and must not depend on Godot. It owns reusable bulk-data and deterministic systems such as:

- spatial cell/relevance selection;
- world-streaming candidate filtering;
- binary tile decoding and validation;
- compression/serialization helpers;
- batching and geometry preparation;
- network snapshot/interest-management primitives;
- shared deterministic server/client simulation helpers where practical.

`yardman_rust` is the GDExtension adapter. It converts Godot packed data to/from `yardman_core` in batches. Avoid fine-grained per-node native calls that would replace GDScript overhead with FFI overhead.

Future `yardman_server` code should depend on `yardman_core` directly and must not require rendering, UI, or a Godot scene tree for authoritative session simulation.

## Online target

The multiplayer direction is authoritative server simulation with streamed-cell interest management, snapshot replication/interpolation, local prediction and reconciliation, persistence/services outside the real-time simulation, and seamless nearby-player presence. These are Yardman implementations informed by public networking techniques; proprietary decompiled game code or copyrighted game assets are not source material.

## Migration rule

Move a production path into Rust only when all of the following are true:

1. the workload is measured or structurally high-volume;
2. the Rust path has exact fixture parity with the current implementation;
3. the GDScript fallback remains available during rollout;
4. Android arm64 compilation is proven before the native path becomes required by the game;
5. frame-time or throughput evidence justifies the added native boundary.
