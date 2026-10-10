# Original runtime audio

`game_audio.gd` supplies four single-voice AudioStreamPlayers: a harmonically
synthesised engine, road/tyre rolling texture, two-strike footstep loop and a
quiet general wind bed. All mono 16-bit 22,050 Hz buffers are generated once,
cached across instances and looped. Integer PCM loop endpoints match. Runtime
updates change pitch/volume/play state; they never generate more PCM or add
voices. These are original sounds, with no downloaded or reference-game audio.

Add the node, optionally call `configure(quality, volume)`, and call
`update_state(delta, state)` with `driving`, `speed_mps`, `rpm`, `on_road`,
`walk_speed`, `ready` and `menu_open`. Optional `throttle` improves estimated
engine load. RPM and load smoothing prevents sudden gear-pitch jumps. Grass
lowers the roll texture's pitch. Walking selects footsteps, standing silences
them, and driving selects the engine and moving tyre noise. A closed streaming
gate or open menu stops all voices. `set_volume(0..1)` provides a master gain,
default 0.60; engine/road cues remain louder than general ambient wind.

Run `godot --headless --audio-driver Dummy --path godot --script
res://tests/audio_test.gd` to check loop bounds/endpoints, nonempty unclipped PCM,
cached stream reuse, the four-voice limit, RPM smoothing, speed/surface changes,
on-foot selection, standing/menu/inactive silence and finite-value handling.
Headless tests do not establish audible quality, phone speaker balance or
on-device latency. The layer is an initial gameplay cue system; geographically
specific surf, birds, traffic, interiors and professionally mixed audio remain
to implement.
