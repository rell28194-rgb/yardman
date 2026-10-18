# Yardman native acceleration lane

This directory is an optional GDExtension performance lane for measured CPU hot paths. It does not replace GDScript orchestration and it is deliberately kept outside `godot/` until a binary is built and staged by the native CI job.

## Rules

- Godot remains 4.7.2 and the project stays Android-first.
- `godot-cpp` is fetched at pinned commit `2bb1acf6f8ae1ce96ac7b9ba3a10b499c59c49ec` and the SCons build explicitly targets API `4.7`.
- Normal source checkouts require no native binary and cannot fail because a `.so` is absent.
- Native kernels are not wired into gameplay until result parity and representative-device benchmarks justify the bridge cost.
- GDScript remains the fallback/authority for UI, menus, state transitions, interaction, and high-level runtime coordination.
- C++ is reserved for batch math, decoding, spatial filtering, geometry preparation, serialization, or other measured bottlenecks.
- Android arm64 builds are added only after the first kernel is accepted; Linux CI proves the extension ABI and functional parity first.

## First kernel

`YardmanNativeKernels.filter_points_in_radius()` and `count_points_in_radius()` model the distance-filter stage repeated by open-world streaming systems. CI builds the extension, loads it into the canonical Godot project, checks exact parity against GDScript over 120,000 deterministic points, and records native/GDScript timing without using noisy hosted-runner timing as a pass/fail threshold.

## High-end engine strategy

Yardman can implement equivalents of missing heavyweight engine features incrementally: shared streaming budgets, hierarchical building/terrain/vegetation LOD, clustered asset batches, occlusion/visibility data, shader/material specialization, and native data kernels. Public papers, open-source implementations, documented engine techniques, and observed behavior may inform those systems. Proprietary decompiled code or copyrighted game assets are not copied into the project.
