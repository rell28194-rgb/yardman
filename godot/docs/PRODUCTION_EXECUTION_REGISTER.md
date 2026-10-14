# Yardman production execution register

Canonical runtime: Godot 4.7.2 under `godot/` on `codex/godot-polish-002`. Full Jamaica, all fourteen parishes, EPSG:3448 registration and one-real-metre scale remain invariant. PR #4 is not merged by this work.

| ID | Subsystem | State | Current evidence / next gate |
|---|---|---|---|
| A-01 | Android renderer architecture | ACTIVE | Android project default moved toward Vulkan Mobile while desktop/headless stays Compatibility. Separate GLES Android export/validation still must be wired and proven. |
| A-02 | Quality tier policy | IMPLEMENTED | Dedicated renderer-aware policy defines FPS, resolution, shadows, road visibility, reflection/effect and water/terrain budgets. Runtime integration remains next. |
| A-03 | Dynamic resolution / thermal ladder | IMPLEMENTED | Hysteretic resolution controller and six-stage degradation policy exist; Android thermal-signal adapter and sustained-device proof remain open. |
| A-04 | Shader/material variants | ACTIVE | Existing terrain/foliage/water shaders remain; formal Vulkan/GLES variant split and warmup scene are not complete. |
| A-05 | Sky / exposure / fog / daylight | IMPLEMENTED | Existing `world_visuals.gd` runtime system retained. Visual acceptance remains open. |
| A-06 | Water / wetness | ACTIVE | Existing coastline/water path retained; renderer-tier variants and wet-road integration remain open. |
| B-01 | Vehicle data platform | IMPLEMENTED | `vehicle_catalog.gd` adds per-car mass, wheelbase, track, CG, power/drag/brake/steer/grip/suspension/gearing/RPM/audio/camera metadata. |
| B-02 | Distinct vehicle physics | IMPLEMENTED | Controller now consumes profile data instead of one global constants block; legacy sedan remains regression baseline. CI/runtime test pending at this checkpoint. |
| B-03 | Toyota Crown | ACTIVE | Handling/data profile exists; dedicated hero mesh/material/audio integration not yet accepted. |
| B-04 | Toyota Mark X | ACTIVE | Handling/data profile exists; dedicated hero mesh/material/audio integration not yet accepted. |
| B-05 | Port Royal 992 parody | ACTIVE | Fictional 992-class handling/data profile exists; dedicated hero mesh/material/audio integration not yet accepted. |
| B-06 | Garage / car-selection UI | NOT STARTED | Next Phase B integration after catalog/controller tests pass. |
| B-07 | Persistent selected vehicle | NOT STARTED | Will be added with garage workflow and save migration-safe default. |

A feature is advanced to TESTED only after the relevant Godot/CI gate runs on the exact source SHA. ACCEPTED remains owner/runtime evidence, not a code-presence label.
