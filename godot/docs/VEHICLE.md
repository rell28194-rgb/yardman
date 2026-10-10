# Vehicle polish

The vehicle is an original procedural compact sedan, 4.3 metres long, with a
profiled bonnet/trunk, crowned roof, inclined tinted windows, framed pillars,
real tyre-arch cutouts, door seams/handles, mirrors, grille, rubber bumpers,
rubber tyres, five-spoke rims and an exhaust. Front wheels visibly steer and
all wheels spin with signed road speed. Brake and reverse lamps follow input.
The model replaces the old VisualRig when the controller is configured.

The CharacterBody3D footprint and canonical parked-coordinate ownership are
preserved. This is a kinematic vehicle, not a complete rigid-body tyre solver.
Road driving uses an acceleration curve, rolling/aerodynamic drag and a
151.2 km/h maximum. Reverse is capped at 25.2 km/h. Off-road resistance and a
64.8 km/h target limit slow a car progressively rather than instantly clamping
its speed at the edge of a road. `on_road` is set from the streamed road surface
by the integration layer; visuals do not determine friction.

`step(delta, throttle, steering, collision_ready)` remains the public update.
`brake_input` is an independent 0..1 service brake and never selects reverse.
Negative throttle brakes existing forward travel before it drives in reverse,
preserving keyboard compatibility. `handbrake` brakes and reduces lateral grip.
`engine_rpm`, `steering_angle` and `gear_label()` provide HUD state. Steering
uses wheelbase and a speed-sensitive angle, then caps yaw using lateral grip;
the car cannot rotate in place or make full-speed pivot turns. Pitch/roll and
ground-normal alignment are smoothed in the visual rig while the physics body
retains its stable collision footprint.

When collision residency is false the controller does not change position,
rotation, velocity, speed or odometer. This is required for a car parked far
from the player. Movement requires collision; geometry can unload without
changing the canonical parked coordinates owned by the world save system.

Run `godot --headless --path godot --script res://tests/vehicle_test.gd` to test
real floor contact, acceleration, actual displacement, braking without reverse,
reverse speed, grip-limited steering, gradual grass deceleration, wheel/lamps,
empty-car input rejection and unloaded-collision freezing. This test does not
measure phone frame time, thermal behaviour, tyre wear or crash deformation.
