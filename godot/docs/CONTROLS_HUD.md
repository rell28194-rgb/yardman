# Controls and HUD polish

The October 9 controls decision is the default: **Stick**. The older four large rectangular buttons are no longer the walking interface. `Buttons` and `Wheel` remain optional vehicle steering modes.

## Touch

- Walking uses a floating left thumb stick. Its vector is normalized, with a configurable deadzone. Main passes that vector to the player in camera coordinates, so forward follows the view rather than rotating the character like a car.
- Drag the right side to look while the left stick remains owned by its original finger. A third finger can hold sprint or a driving pedal.
- Driving has analog left steering and separate pedals explicitly labelled **GAS** and **BRAKE**. Their original line drawings show a tall accelerator and a wide brake pedal. **REVERSE** toggles direction and has a gold selected state; **HANDBRAKE** is held independently. Braking never silently selects reverse.
- Enter/leave appears only when the actor can interact with the nearby stopped vehicle. The existing collision query still determines whether leaving is safe.
- Each pressed finger owns one role until release. Dragging outside a button does not transfer a pedal into the look gesture. Focus loss, menus and vehicle transitions clear all ownership.
- Control size, opacity, sensitivity, vertical-look inversion, deadzone and steering mode are configurable in the menu. Reposition mode stores normalized screen positions. Layout editing produces no movement or pedal input.
- Increasing control size also increases the default distance between pedals and action rows. Hit areas remain separate at the maximum 140% setting. A floating walking stick can be displayed inside the screen margin while retaining its actual touch origin, so a press at an edge does not start moving the player.
- The touch canvas redraws after changed input, layout, mode or viewport state. Main may assign its current driving state every frame without clearing fingers or regenerating the canvas. Look-only drags do not redraw static pedals.

Desktop hides touch glyphs. WASD/arrows, Shift and E remain available. Right mouse drag looks; Escape opens the menu.

## HUD

Permanent elements are a compact road radar and parish/time label, compass, vehicle speed and gear, and menu button. FPS, height, save/recover buttons and graphics/travel dropdowns no longer cover the world.

Charcoal panels use cream text, green navigation/selection accents and gold active input/heading cues. The menu owns travel, graphics, save/recover, credits and control settings. Its full viewport blocker clears active fingers and suspends controls through `menu_toggled`; main must also gate keyboard movement while it is open.

The drawer scrolls within the viewport, including at a 960 × 540 logical layout. Slider labels show actual deadzone, sensitivity, size and opacity values. The permanent canvas refreshes when visible speed, compass, minute, status or radar values change instead of treating identical physics updates as new HUD content. These are usability repairs to the saved theme; final interface matching still requires inspection of the owner's actual game references.

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

The test exercises analog pedal/steering/look ownership, walking deadzone/diagonal magnitude, sprint, separate brake/reverse, optional steering modes, settings, normalized layout editing, focus loss, menu input blocking, pending travel selection, restored settings, radar clipping and original limb animation. It also checks scaled hit-area separation, safe margins, edge touches and compact menu scrolling. It does not claim measured comfort on a phone; the next user playtest is still needed for ergonomics.

`controls_render_test.gd` is an optional GL compatibility render fixture. Set `YARDMAN_HUD_CAPTURE_DIR` and run it with a display to produce eight full-size interface frames: driving, walking, both optional steering modes, the top and bottom of settings, maximum controls in a compact layout, and its menu. It verifies that idle touch input does not redraw its canvas. The fixture background is for HUD inspection and is not a gameplay screenshot.
