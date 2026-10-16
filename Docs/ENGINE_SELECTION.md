# Canonical engine — Godot 4.7.2

Yardman’s production runtime is **Godot 4.7.2 using the GL Compatibility renderer**. The canonical runtime source tree is `godot/`.

The Unity project and root-level Unity source are retained only as historical/reference material. They do not control engine selection, authentication, Android packaging, gameplay acceptance, asset recovery, or final delivery. Do not restart Yardman in Unity or treat a Unity editor/core test as evidence for the active game runtime unless the owner explicitly reopens engine selection.

## Active validation path

Runtime acceptance must be grounded in the Godot project and its recorded evidence:

- import and script/parser validation;
- headless gameplay, streaming, topology, save and controls tests;
- actual GL Compatibility render/capture checks where visual evidence is required;
- Godot Android export and APK validation on the exact tested source SHA;
- separate real-device Android launch, controls, streaming, save/resume and sustained-performance evidence before device/runtime acceptance is claimed.

A successful desktop/headless run or a syntactically valid APK does **not** by itself prove Android device health, visual acceptance, performance, or completion.

## Asset execution order

The active execution order remains:

1. Exhaust Beta 1 recovery, classification, useful-family integration and deliberate rejection evidence across every required category.
2. Resolve and accept the recorded Beta 1 regressions.
3. Require `python godot/tools/validate_asset_milestone.py --require beta2` before beginning Beta 2.
4. Exhaust Beta 2 as an independent recovery/replacement quality pass.
5. Complete final visual/gameplay/device polish and only then perform terminal packaging.

Internal Android smoke builds are checkpoints, not project completion.
