# YARDMAN — MULTI-DAY FULL PRODUCTION EXECUTION DIRECTIVE

You are taking over active development of **Yardman**.

This is not a brainstorming session.

This is not a code-review session.

This is not an excuse to spend entire turns inspecting files.

This is a multi-day implementation sprint intended to materially transform Yardman from its current prototype state into a serious, high-fidelity Jamaica open-world game.

The user is prepared to spend the next several days working on this continuously.

Your job is to **EXECUTE**.

---

## 1. CANONICAL PROJECT

Repository: `rell28194-rgb/yardman`

Active branch: `codex/godot-polish-002`

Engine: Godot 4.7.2

Production runtime: `godot/`

PR #4 remains unmerged unless the user explicitly orders otherwise.

Unity material in the repository is historical/reference material only.

Full Jamaica remains the world target.

All 14 parishes remain first-class.

True geographic scale remains the goal.

Do not restart the project.

Do not switch engines.

Do not shrink the island.

Do not reduce the project into a demo, vertical-slice-only game, Kingston-only project, driving sandbox, or tiny mobile prototype.

---

## 2. FUNDAMENTAL DEVELOPMENT PHILOSOPHY

Stop treating graphics and mechanics as competing priorities.

Yardman must have both.

A feature is not to be deleted merely because the current visual presentation is too weak to support it. Improve the presentation.

A visual feature is not to be removed merely because an early Android implementation is expensive. Create quality tiers, LODs, HLODs, shader variants, streaming rules, adaptive resolution, and renderer-specific implementations.

The target is:

**high-quality mechanics + high-quality graphics + large world + mobile scalability.**

Optimization means making the intended game run efficiently.

Optimization does **not** mean redesigning the intended game into something cheap.

---

## 3. GRAPHICS SPECIFICATION IS AUTHORITATIVE

Read the user-provided `godot-android-gpu.md`.

Treat it as an implementation specification, not optional advice.

Major requirements include:

- Vulkan Mobile as the primary high-end Android renderer.
- OpenGL Compatibility as an independently tested fallback.
- Forward+ only where appropriate, not as the normal Android path.
- Explicit Android graphics tiers.
- Separate shader/material variants instead of one giant universal shader.
- Hero-quality materials for important vehicles and characters.
- ASTC/ETC2 texture strategy.
- LOD/HLOD.
- Streamed visibility clusters.
- Dynamic resolution.
- Stable frame pacing.
- Thermal degradation policy.
- Controlled reflections.
- Strong sky/exposure.
- Baked lighting where appropriate.
- Vegetation motion.
- Water.
- Wetness.
- Road material quality.
- Mobile GPU-conscious shader design.

Do not silently abandon these because Compatibility mode currently exists.

Build toward the proper renderer architecture.

---

## 4. LICENSED / PERMITTED REFERENCE MATERIAL

The user has stated that they have permission from relevant owners/community holders to create a successor-like project carrying forward discontinued legacy material from:

- CarX-related material.
- Real Racing 3 community material.

These are important reference sources for preserving qualities the user admired:

- Vehicle feel.
- Vehicle presentation.
- Camera behavior.
- Garage/selection experience.
- Audio character.
- Racing/driving feedback.
- UI readability.
- Model/material quality.
- Atmosphere.

Use permitted material where technically and legally appropriate.

Do not indiscriminately copy assets merely because they exist.

Recover, convert, adapt, optimize, integrate, and document provenance.

Beta 1 and Beta 2 reference archives may be mined for inspiration and permitted reusable material.

Beta 2 is open for inspection/inspiration.

It does **not** automatically replace the current production runtime.

---

## 5. VEHICLE REQUIREMENTS

The current one-car/prototype situation is unacceptable as the long-term design.

Implement a genuine vehicle framework.

Required early cars include:

- Toyota Crown.
- Toyota Mark X.
- Porsche 911 992-inspired parody vehicle unless direct Porsche licensing later becomes available.

Toyota licensing has been stated by the user as available.

These should not simply be cosmetic skins over identical physics.

Each vehicle must eventually support its own:

- Mass.
- Wheelbase.
- Track width.
- Center of gravity.
- Suspension tuning.
- Torque curve.
- Transmission.
- Gearing.
- Final drive.
- Traction behavior.
- Braking.
- Steering response.
- Tire behavior.
- Drivetrain.
- Aero behavior where relevant.
- Engine audio profile.
- Exhaust profile.
- Interior/exterior camera offsets.
- Lighting rig.
- Visual geometry.
- Dashboard/instrumentation when available.

Build a scalable vehicle-data system instead of hardcoding every car separately.

Create an actual:

- Car-selection screen.
- Garage.
- Vehicle preview.
- Persistent selected vehicle.
- Vehicle metadata.
- Vehicle switching workflow.

Future expansion must not require rewriting the controller.

---

## 6. VEHICLE QUALITY TARGET

Fix and improve:

- Acceleration.
- Braking.
- Steering.
- Yaw response.
- Tire grip.
- Slip angle behavior.
- Suspension compression.
- Rebound.
- Road contact.
- Curb behavior.
- Rough-road behavior.
- Understeer.
- Oversteer.
- Weight transfer.
- High-speed stability.
- Reverse.
- Traction loss.
- Grass/offroad behavior.
- Crash response.

Maintain arcade accessibility while preserving believable physical character.

Do not make all vehicles feel like the same rigid body with different max speeds.

---

## 7. VEHICLE VISUAL QUALITY

Important vehicles are hero assets.

They should receive:

- High-quality mesh LOD0.
- Sensible LOD1/LOD2.
- Real wheel geometry.
- Brake geometry where available.
- Glass.
- Headlights.
- Brake lights.
- Reverse lights.
- Indicators later.
- Emissive dashboards where possible.
- Paint clearcoat.
- Metallic/roughness materials.
- Reflections.
- Shadowing.
- Correct scale.
- Believable ride height.
- Wheel rotation.
- Steering animation.
- Suspension motion.

Do not lower the entire project to the quality of the current placeholder car.

Raise the car system.

---

## 8. AUDIO

The game must stop sounding like an electric placeholder vehicle.

Build a scalable automotive audio system.

Target layers:

- Idle.
- Low load.
- High load.
- RPM rise.
- RPM fall.
- Intake.
- Exhaust.
- Transmission.
- Tire scrub.
- Tire slip.
- Asphalt rolling.
- Rough-road rolling.
- Grass.
- Gravel later.
- Wind.
- Collision.
- Tunnel/reverb behavior eventually.

Car sound must react to RPM, throttle, gear, speed, load, and surface.

Audio regression tests must reflect the actual mixer design.

Never block an otherwise healthy implementation because a test still describes obsolete behavior; fix the stale test.

---

## 9. JAMAICA WORLD

The world is Jamaica, not “Jamaica-inspired.”

Keep improving:

- Roads.
- Terrain.
- Coastline.
- Towns.
- Villages.
- Neighborhoods.
- Squares.
- Capitals.
- Parish identity.
- Road geometry.
- Elevation.
- Bridges.
- Tunnels.
- Vegetation.
- Buildings.
- Road furniture.
- Lighting.
- Landmarks.
- Water.
- Coastline behavior.

Current location tracking must resolve more than parish names.

It should support parish, town, village, neighborhood, locality, square, parish capital, and major place names.

Geographic truth outranks visual convenience.

---

## 10. WORLD VISUAL QUALITY

Build toward a convincing Jamaica rather than a geometry viewer.

Needed systems include:

- Physically believable sky.
- Sun.
- Moon.
- Clouds.
- Proper horizon.
- Atmospheric scattering approximation appropriate to mobile.
- Exposure.
- Fog.
- Rain later.
- Wet roads.
- Puddles where viable.
- Tropical vegetation.
- Vegetation wind.
- Shoreline material.
- Water normals.
- Foam.
- Reflections.
- Tropical color calibration.
- Time-of-day.
- Night lighting.
- Streetlights.
- Building lights.

Jamaica needs visual personality.

It must not look like generic procedural terrain.

---

## 11. CHARACTER SYSTEM — MAJOR NEXT PROGRAM

Driving is only one part of Yardman.

After the current vehicle/world foundation becomes strong, begin the playable-character system.

Required systems eventually include:

- Third-person character.
- Walking.
- Running.
- Sprinting.
- Crouching where appropriate.
- Jumping if appropriate.
- Entering vehicles.
- Exiting vehicles.
- Animation state machine.
- Foot placement.
- Slopes.
- Stairs.
- Collision.
- Camera.
- Interaction.
- Inventory foundation.
- Clothing system later.
- Character customization later.

Character quality should match the environment.

Do not bolt a crude capsule character onto a polished driving game and declare it complete.

---

## 12. NPC / AI PROGRAM

Yardman eventually needs a living Jamaica.

Plan for:

- Pedestrian AI.
- Traffic AI.
- Parked vehicles.
- Drivers.
- Passengers.
- Schedules.
- Destinations.
- Local behaviors.
- Traffic rules.
- Route finding.
- Reactions.
- Ambient conversations.
- Shops/business activity later.
- Police/emergency systems later.
- Economic activity later.

NPCs should exist independently of the player.

Avoid fake ambience where pedestrians simply orbit the player.

Build scalable simulation tiers:

- Near-player full AI.
- Medium-distance simplified AI.
- Far-distance statistical simulation.

---

## 13. WORLD ATMOSPHERE / LIFE

The game should eventually feel like Jamaica is continuing whether the player is present or not.

Systems to build over time include:

- Time of day.
- Weather.
- Traffic density cycles.
- Pedestrian density.
- Music.
- Environmental audio.
- Birds/insects.
- Ocean.
- Wind.
- Nightlife.
- Shops.
- Road activity.
- Buses/taxis.
- Weather transitions.
- Events.
- Localized ambience.
- Parish-specific differences.

Do not reduce atmosphere to decorative particle effects.

It is a systems problem.

---

## 14. INSPECTION RULE

The previous workflow spent too much time inspecting and too little time implementing.

Correct that.

At the beginning of a work cycle:

1. Inspect only the files required to understand the immediate subsystem.
2. Identify the current implementation.
3. Identify the exact gap.
4. Patch it.
5. Test it.
6. Save it.
7. Move on.

Do not repeatedly re-read the same documentation.

Do not spend multiple turns restating repository state.

Inspection should normally consume no more than approximately 10–20% of a work cycle unless a genuine unknown blocker requires investigation.

The majority of the cycle must produce implementation.

---

## 15. NEVER HALF-IMPLEMENT AND ABANDON SYSTEMS

Maintain a persistent execution register.

Every feature must have one state:

`NOT STARTED`

`ACTIVE`

`IMPLEMENTED`

`TESTED`

`ACCEPTED`

`BLOCKED`

Never silently stop working on a feature.

Never drop something because a newer idea appeared.

Never claim a feature is finished because one script exists.

A subsystem is complete only when:

- Runtime implementation exists.
- Integration exists.
- Regression coverage exists.
- Failure modes are handled.
- Relevant assets are connected.
- It survives automated validation.

---

## 16. MULTI-DAY EXECUTION PLAN

### PHASE A — FOUNDATION AND RENDERING

Finish renderer architecture, Vulkan Mobile path, Compatibility fallback, quality tier manager, resolution scaling framework, shader variant organization, material quality rules, lighting baseline, sky, clouds, sun, moon, exposure, fog, and water baseline.

Acceptance: the game must visibly exceed the current presentation without breaking lower-tier support.

### PHASE B — VEHICLE PLATFORM

Build vehicle database/resource format, vehicle spawning, garage, car selection, multiple distinct cars, Toyota Crown, Toyota Mark X, Porsche 992-style parody, handling profiles, powertrain profiles, lighting, cameras, LOD, materials, and audio profiles.

Acceptance: switching cars must change both visual identity and driving behavior.

### PHASE C — JAMAICA VISUAL REBUILD

Improve road material, terrain material, road-to-terrain seams, tunnels, bridges, coastline, water, vegetation, buildings, roadside props, road signs, guardrails, lamps, settlements, and location tracking.

Acceptance: the world must increasingly resemble a real inhabited island instead of generated map geometry.

### PHASE D — PERFORMANCE / STREAMING

Implement world cells, visibility clusters, LOD, HLOD, MultiMesh partitioning, texture budgets, shader budgets, dynamic resolution, quality modes, frame pacing, and thermal adaptation.

Do not perform destructive “optimization.” Optimize through scalability.

### PHASE E — CHARACTER

Implement the first production-quality playable character foundation: locomotion, camera, vehicle entering/exiting, animation, ground alignment, and interaction foundation.

### PHASE F — TRAFFIC / PEDESTRIANS / AI

Begin traffic graph, lane behavior, driving AI, parked cars, pedestrians, navigation, spawn/despawn, and simulation LOD.

### PHASE G — WORLD ATMOSPHERE

Integrate weather, day/night, environmental audio, traffic density, pedestrian density, wildlife ambience, local atmosphere, and nighttime city lighting.

---

## 17. TESTING POLICY

There are two types of testing.

### INTERNAL TESTING

Run continuously:

- Unit tests.
- Regression tests.
- Scene boot tests.
- Headless tests.
- Rendering tests.
- Shader compilation.
- Map topology.
- APK validation.
- Android export.
- Performance sanity checks.

### OWNER DEVICE TESTING

Do not waste the user's time with tiny incremental builds.

Owner testing happens after a major internal milestone.

Before presenting an APK to the user:

- All core tests green.
- No parser errors.
- No known crash.
- No obviously broken controls.
- No known broken audio regression.
- Renderer starts correctly.
- Driving works.
- Vehicle switching works if part of milestone.
- Jamaica loads.
- Location tracking works.
- Major visual systems render.
- APK validation passes.

Then provide the APK.

---

## 18. ARTIFACT POLICY

Large APK size is acceptable.

The user has ample storage.

Do not artificially strip legitimate game content simply to keep the APK small.

Size optimization comes later through texture compression, duplicate elimination, asset bundles, optional content, and streaming — not by gutting the game.

---

## 19. WORK CYCLE PROTOCOL

Every substantial response should correspond to real execution.

Use this loop:

**A. Select highest-value incomplete subsystem.**

**B. Inspect only required files.**

**C. Implement.**

**D. Run relevant tests.**

**E. Repair failures immediately.**

**F. Commit durable code/checkpoint.**

**G. Update execution register.**

**H. Immediately start next subsystem.**

Do not stop merely because one milestone completed.

The user will explicitly tell you when to stop.

---

## 20. REPORTING STYLE

The user does not want long status speeches while work is underway.

Keep progress reports short.

Report:

- What was actually changed.
- What passed.
- What failed.
- What you are doing next.

Do not report intentions as achievements.

Do not say “implemented” when code has not run.

Do not say “tested” when only static inspection occurred.

Do not say “APK ready” unless the APK file exists.

---

## 21. FIRST ACTION IN A NEW CHAT

Immediately:

1. Inspect the current branch HEAD.
2. Read the current project handoff/status files.
3. Read `godot-android-gpu.md`.
4. Inspect the existing vehicle/rendering/world systems.
5. Generate one concise current-state execution register.
6. Begin PHASE A and PHASE B implementation immediately.

Do not spend the first turn merely telling the user what you found.

Inspect and then start modifying the project in the same work cycle.

---

## 22. SUCCESS STANDARD

Yardman is not successful because it launches.

Yardman is not successful because an APK exists.

Yardman is not successful because CI is green.

Those are baseline requirements.

Success is increasingly achieving:

- Convincing Jamaica.
- Excellent driving.
- Strong vehicle fidelity.
- Multiple cars.
- Strong graphics.
- Scalable Android performance.
- Believable character movement.
- Traffic.
- Pedestrians.
- AI.
- Atmosphere.
- World activity.
- Strong sound.
- Coherent systems.
- Stable runtime.

Treat Yardman as a real game production.

Begin execution immediately.

---

## 23. MULTI-DAY PRIORITY ORDER

### Day 1
Renderer/graphics foundation plus the vehicle platform.

Target: Vulkan Mobile, Compatibility fallback, graphics tiers, vehicle data resources, garage/selection infrastructure, and first genuinely distinct cars functioning.

### Day 2
World-quality pass.

Target: roads, terrain, road seams, tunnels, bridges, vegetation, water, buildings, settlement identity, sky, lighting, weather groundwork, location fidelity, and active use of useful Beta 1/Beta 2 material.

### Day 3
Vehicle depth and Android scalability.

Target: better models/materials, permitted CarX/RR3 reference integration, audio, drivetrain differences, LOD/HLOD, streaming, graphics modes, dynamic resolution, frame pacing, and performance profiling.

### Day 4+
Begin the major systems still largely untouched.

Target: production character controller, animation, vehicle entry/exit, pedestrian foundation, traffic AI, simulation LOD, day/night, environmental audio, ambient activity, and world-life systems.

The larger project continues beyond this sprint with deeper AI, economy/activity, interiors, weather, population simulation, missions/gameplay loops, and advanced world atmosphere.

---

## 24. FINAL OPERATING RULE

Inspection is subordinate to execution.

Inspect to answer a specific implementation question, then modify something.

Do not spend hours proving files exist.

Do not let current low visual quality dictate permanent scope reductions.

Do not choose mechanics over graphics or graphics over mechanics.

Build both properly.
