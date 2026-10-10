# Controls and HUD polish

The October 9 controls decision is the default: **Stick**. The older four large rectangular buttons are no longer the walking interface. `Buttons` and `Wheel` remain optional vehicle steering modes.

## Touch

- Walking uses a floating left thumb stick. Its vector is normalized, with a configurable deadzone. Main passes that vector to the player in camera coordinates, so forward follows the view rather than rotating the character like a car.
- Drag the right side to look while the left stick remains owned by its original finger. A third finger can hold sprint or a driving pedal.
- Driving has analog left steering, separate gas and brake, a D/R direction selector and a handbrake. Braking never silently selects reverse.
- Enter/leave appears only when the actor can interact with the nearby stopped vehicle. The existing collision query still determines whether leaving is safe.
- Each pressed finger owns one role until release. Dragging outside a button does not transfer a pedal into the look gesture. Focus loss, menus and vehicle transitions clear all ownership.
- Control size, opacity, sensitivity, vertical-look inversion, deadzone and steering mode are configurable in the menu. Reposition mode stores normalized screen positions. Layout editing produces no movement or pedal input.

Desktop hides touch glyphs. WASD/arrows, Shift and E remain available. Right mouse drag looks; Escape opens the menu.

## HUD

Permanent elements are a compact road radar and parish/time label, compass, vehicle speed and gear, and menu button. FPS, height, save/recover buttons and graphics/travel dropdowns no longer cover the world.

Charcoal panels use cream text, green navigation/selection accents and gold active input/heading cues. The menu owns travel, graphics, save/recover, credits and control settings. Its full viewport blocker clears active fingers and suspends controls through `menu_toggled`; main must also gate keyboard movement while it is open.

`set_radar_paths` consumes world/local-coordinate road paths and the actor's center in the same coordinate system. It clips visible lines to a circular 210 metre radar extent and rotates them by Godot yaw. This is a road display, not an invented navigation route.

## Main integration contract

Create `hud.gd` under the HUD canvas, call `configure(parishes, qualities)`, then `attach_controls(touch)`. Connect `travel_requested`, `quality_requested`, `save_requested`, `recover_requested`, `interaction_requested`, `credits_requested` and `menu_toggled`.

`set_status` keys: `parish`, `speed_kmh`, `driving`, `ready`, `can_interact`, `message`, `heading` (Godot world yaw), `gear`, `time_hour`. Call `select_quality` when a graphics profile changes. Travel selection remains pending while the user chooses; repeated status refreshes do not overwrite it.

Read `touch.movement_vector()` and `sprint_held()` on foot. Read `throttle()`, `steering()`, `brake()` and `handbrake_held()` while driving. `consume_look()` returns accumulated look displacement once. Save `get_settings()` and restore via `apply_settings()` in the world save record. `reduced_motion` turns off player body bobbing while preserving limb animation.

The original procedural character now has opposed arm/leg motion, shoes, a simple face and hair. It remains an early original asset; this change is not a claim of finished character art.

## Regression command

```
godot --headless --path godot --script res://tests/controls_hud_test.gd
```

The test exercises analog pedal/steering/look ownership, walking deadzone/diagonal magnitude, sprint, separate brake/reverse, optional steering modes, settings, normalized layout editing, focus loss, menu input blocking, pending travel selection, restored settings, radar clipping and original limb animation. It does not claim measured comfort on a phone; the next user playtest is still needed for ergonomics.
