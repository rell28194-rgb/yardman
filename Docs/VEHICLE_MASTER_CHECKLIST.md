# Yardman vehicle master checklist

This checklist is mandatory for every Beta 1 / Beta 2 vehicle. A vehicle does not pass because its body mesh renders.

## 0. Identity and provenance

- [ ] canonical internal source ID located
- [ ] human vehicle identity supported by source evidence
- [ ] source game/package/version recorded
- [ ] exact source container/member paths recorded
- [ ] hashes recorded for every recovered source member
- [ ] variant relationships recorded (trim/year/race/upgrade/body-kit variants)
- [ ] uncertain identity explicitly marked instead of guessed

## 1. Source dependency closure

### Geometry
- [ ] exterior/chassis/body master
- [ ] all useful exterior LODs
- [ ] interior/cockpit master and LODs
- [ ] underside/engine bay if present
- [ ] glass and mirrors
- [ ] headlight/taillight/lens/emissive geometry
- [ ] trim, grilles, badges, exhaust, diffusers and small exterior pieces
- [ ] wheel/rim variants
- [ ] tyres
- [ ] brakes/calipers/discs/hubs
- [ ] driver/steering wheel dependencies where vehicle-specific
- [ ] customization geometry: bumpers, skirts, hoods, spoilers, fenders, cages, etc.
- [ ] damage/deformation meshes if the source supports them

### Materials and textures
- [ ] source material list preserved
- [ ] paint/material slot semantics recovered
- [ ] albedo/base-color maps
- [ ] normal maps
- [ ] roughness/gloss/specular/metalness maps or conversion evidence
- [ ] AO/lightmaps where relevant
- [ ] emissive/light maps
- [ ] glass maps/parameters
- [ ] interior maps
- [ ] tyre/rim/brake maps
- [ ] decals/liveries/stickers
- [ ] damage/dirt maps where present
- [ ] source shader parameters recorded before translation

### Rig and spatial data
- [ ] source unit scale established
- [ ] coordinate handedness/front/up axes established
- [ ] wheel pivots/anchors
- [ ] suspension pivots/travel data where present
- [ ] steering pivots
- [ ] center of mass / authored bounds where recoverable
- [ ] door/hood/trunk pivots or bones
- [ ] light origins
- [ ] exhaust origins
- [ ] camera/seat points
- [ ] entry/exit points or equivalent source evidence
- [ ] collision/physics shapes

### Behavior/configuration
- [ ] mass
- [ ] drivetrain
- [ ] torque/power curve or best source equivalent
- [ ] engine redline/idle
- [ ] gearbox ratios/final drive
- [ ] differential parameters where present
- [ ] suspension stiffness/damping/travel
- [ ] steering limits/rate
- [ ] tyre/grip parameters
- [ ] brake parameters
- [ ] aero/downforce if present
- [ ] tuning presets
- [ ] upgrade stages and their actual parameter changes
- [ ] customization compatibility rules

### Audio/VFX
- [ ] idle/on/off-throttle engine layers
- [ ] intake/turbo/supercharger layers if present
- [ ] exhaust layers
- [ ] transmission/gear-shift events if present
- [ ] tyre/skid/surface behavior
- [ ] collision/impact events
- [ ] backfire/pop events if present
- [ ] exhaust smoke/flame definitions where present
- [ ] light/brake/reverse/indicator behavior where present

### Original-game assembly evidence
- [ ] prefab/entity/scene/config root identified
- [ ] references from root to dependencies mapped
- [ ] customization menu/data references mapped
- [ ] upgrade/tune data references mapped
- [ ] spawn/garage/inspection references mapped
- [ ] source behavior that cannot be directly reused is documented for Godot reimplementation

## 2. Neutral source master

- [ ] geometry decoded without destructive reduction
- [ ] source-max detail preserved
- [ ] original hierarchy preserved in metadata
- [ ] transforms normalized reproducibly
- [ ] materials translated to a neutral manifest
- [ ] textures exported losslessly or with documented unavoidable conversion
- [ ] animations/pivots exported
- [ ] audio decoded with event/bank relationship preserved
- [ ] conversion report records dropped/unsupported source data
- [ ] neutral master hashes recorded

Preferred neutral forms where appropriate:
- geometry: GLB/glTF + sidecar manifest
- textures: lossless PNG/TIFF source cache; derived KTX2 for runtime
- audio: WAV/FLAC source cache; derived OGG where appropriate
- structured data: JSON with original raw values retained

## 3. Godot vehicle construction

- [ ] dedicated vehicle scene; no unrelated host-car visual substitution
- [ ] source-max inspection/garage model available
- [ ] runtime LOD chain generated from the preserved master
- [ ] exterior materials physically coherent
- [ ] paint is independently controllable
- [ ] glass behaves as glass
- [ ] mirrors/lights/emissives function correctly
- [ ] interior is complete at near distance
- [ ] wheels/tyres/brakes are correctly aligned and rotate independently
- [ ] suspension/steering visual motion matches physics
- [ ] collision shape matches vehicle dimensions
- [ ] CameraMount correct
- [ ] DriverSeat correct
- [ ] ExitPoint safe
- [ ] exhaust/light sockets correct
- [ ] vehicle controller receives source-derived configuration

## 4. Customization and upgrade parity

A high-detail vehicle is incomplete if its source game exposes meaningful customization/upgrades that Yardman ignores.

- [ ] paint/material channels exposed
- [ ] source rim/wheel variants exposed
- [ ] body-kit components supported
- [ ] spoiler/hood/bumper/skirt/fender variants supported where source-backed
- [ ] livery/decal variants supported where source-backed
- [ ] ride-height/wheel fitment changes remain visually valid
- [ ] performance upgrade stages alter actual runtime parameters
- [ ] tuning menu values map to real physics values
- [ ] customization persists through save/load
- [ ] incompatible combinations are prevented by data, not visual luck

## 5. Driving and interaction gate

- [ ] spawn cleanly in isolated vehicle test scene
- [ ] forward drive
- [ ] reverse
- [ ] steering
- [ ] braking
- [ ] handbrake/drift behavior if supported
- [ ] suspension travel
- [ ] wheel contact stable
- [ ] collision stable
- [ ] reset/despawn stable
- [ ] enter vehicle
- [ ] exit vehicle
- [ ] re-enter vehicle
- [ ] park state
- [ ] odometer/distance integration
- [ ] camera switching
- [ ] lights
- [ ] audio responds correctly to RPM/load/surface
- [ ] customization does not break driving or collision

## 6. Visual inspection gate

Inspect at minimum:
- [ ] front 3/4
- [ ] rear 3/4
- [ ] side profile
- [ ] roof/hood/trunk
- [ ] underbody if visible
- [ ] cockpit/driver view
- [ ] dashboard/instrument surfaces
- [ ] wheel/brake close-up
- [ ] glass/reflections
- [ ] head/tail/brake/reverse lights
- [ ] each customization family
- [ ] source-max vs runtime LOD transitions

Reject for:
- missing body sections
- black/unbound materials
- stretched/skewed geometry
- floating wheels
- host-car leftovers
- incorrect material role mapping
- missing interior
- fake wheel discs baked into body when real wheels exist
- LOD popping that changes vehicle identity
- customization clipping that is not present in source

## 7. Android/performance gate

Maximum detail is preserved in the master, but runtime variants must be scalable.

- [ ] source-max master remains untouched
- [ ] near/garage LOD budget measured
- [ ] gameplay LOD budget measured
- [ ] traffic/distance LOD budget measured
- [ ] texture residency measured
- [ ] material/shader count measured
- [ ] draw calls measured
- [ ] physics cost measured
- [ ] no unexpected asset duplication in memory
- [ ] LOD thresholds deterministic
- [ ] mobile fallback does not corrupt materials or silhouette

## 8. Acceptance evidence

A vehicle is ACCEPTED only when the evidence bundle contains:
- [ ] source manifest
- [ ] dependency closure report
- [ ] conversion report
- [ ] Godot scene/resource manifest
- [ ] structural validator results
- [ ] visual inspection captures
- [ ] isolated driving test results
- [ ] customization/upgrade test results
- [ ] Android/runtime results when applicable
- [ ] explicit self-critique with unresolved defects

Status vocabulary:
- DISCOVERED: identity/source candidate only
- RECOVERED: source dependency pack captured
- CONVERTED: neutral master produced
- INTEGRATED: Godot scene exists
- GAME-READY: driving/interaction gates pass
- HIGH-FIDELITY: visual/customization/source-parity gates pass
- ACCEPTED: owner/device evidence passes and no critical known defect remains

Never skip status stages in reports.
