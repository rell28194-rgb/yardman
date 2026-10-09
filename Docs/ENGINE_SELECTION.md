# Engine selection remains open

`6000.3.24f1` is the **provisional source-bootstrap editor**, not a completed engine-selection decision. It provides a concrete project version while cloud access is being restored. No cloud availability, platform compatibility or runtime advantage is claimed from this pin.

The source uses a small built-in-renderer fixture with engine modules only. This avoids selecting or inventing a URP package lock before an actual editor import. Built-in rendering is not the shipping renderer decision. Renderer/package comparison must follow the project graphics requirements.

Evaluate eligible Unity 7 and Unity 6 candidates using cloud-reported editor availability, successful Android and iOS export/build support, required package compatibility, crash behavior, measured CPU/GPU frame time, memory, sustained-device thermals and visual quality at equivalent content/settings. Unity 7 is allowed to win.

Run the same synthetic streaming fixture and later a representative populated visual scene for each viable candidate. Preserve exact editor, package locks, source commit, target configuration and device results. Pin the winner only after these results support it; a local core-test pass does not select an engine.

References consulted on 2026-10-09:

- https://unity.com/releases/editor/whats-new/6000.3.24f1
- https://unity.com/releases/editor/alpha/7000.0.0a7
- https://docs.unity.com/en-us/oas-build-automation-client/2.0.0
