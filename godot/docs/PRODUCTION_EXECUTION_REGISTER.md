# Yardman production execution register

Canonical runtime: Godot 4.7.2 under `godot/` on `codex/godot-polish-002`. Full Jamaica, all fourteen parishes, EPSG:3448 registration and one-real-metre scale remain invariant. PR #4 is not merged by this work.

| ID | Subsystem | State | Current evidence / next gate |
|---|---|---|---|
| A-01 | Android renderer architecture | TESTED | Vulkan Mobile is the canonical Android path and a separately configured GLES fallback exported and signature-verified in the renderer matrix. Owner-device acceptance remains open. |
| A-02 | Quality tier policy | TESTED | Renderer-aware Performance/Balanced/Quality/Ultra/Custom budgets and GLES caps pass the focused platform gate. |
| A-03 | Dynamic resolution / thermal ladder | TESTED | Hysteretic resolution scaling and six-stage visual degradation are regression-covered; Android OS thermal-signal input and sustained-device validation remain open. |
| A-04 | Shader/material variants | TESTED | Distinct high/safe road, water and terrain shaders compile and switch at runtime; shader prewarm remains open. |
| A-05 | Sky / exposure / fog / daylight | IMPLEMENTED | Existing `world_visuals.gd` runtime system retained. Visual acceptance remains open. |
| A-06 | Water / wetness | ACTIVE | Tiered coastline water is integrated and tested; wet-road/puddle behavior is not complete. |
| A-07 | Shader prewarm | NOT STARTED | Separate material variants now exist; representative pipeline prewarm is the next rendering-stutter gate. |
| B-01 | Vehicle data platform | TESTED | Catalog provides per-car dimensions, mass/CG, power, braking, steering, grip, suspension, gearing, RPM, audio and camera metadata. |
| B-02 | Distinct vehicle physics | TESTED | Controller consumes profiles and the Crown, Mark X and Port Royal 992 no longer share one hard-coded handling tune. |
| B-03 | Toyota Crown | ACTIVE | Data, handling, garage slot and distinct acoustic bank are tested. Dedicated Crown hero geometry remains unconfirmed/pending. |
| B-04 | Toyota Mark X | ACTIVE | Data, handling, garage slot and distinct acoustic bank are tested. Dedicated Mark X hero geometry remains unconfirmed/pending. |
| B-05 | Port Royal 992 parody | ACTIVE | Data, handling, garage slot and distinct acoustic bank are tested. Dedicated 992-class hero geometry remains unconfirmed/pending. |
| B-06 | Garage / car-selection UI | TESTED | Touch-visible GARAGE button, modal selector, preview and live controller bridge pass the focused gate. |
| B-07 | Persistent selected vehicle | TESTED | Selection writes and parses `user://yardman/vehicle.json` in regression coverage. |
| B-08 | Layered automotive audio | TESTED | Fixed ten-voice mixer covers idle/low/high-load/exhaust/transmission/road/offroad/scrub/footsteps/wind with per-car engine banks. |
| B-09 | Hero vehicle visual/material pipeline | IMPLEMENTED | Shared/recovered geometry now has a non-destructive profile-driven paint/glass/wheel styling layer; focused runtime test pending. Dedicated car meshes remain a separate asset gate. |

A feature is advanced to TESTED only after the relevant Godot/CI gate runs on the exact source SHA. ACCEPTED remains owner/runtime evidence, not a code-presence label.
