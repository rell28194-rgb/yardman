# Yardman execution checkpoints

The latest owner directive is recorded in `AGENTS.md` and
`godot/docs/ASSET_EXECUTION.md`. Exhaust and validate Beta 1 before opening
Beta 2; then finish Beta 2 quality replacements and game polish before terminal
APK packaging. Internal Android builds remain useful health checks throughout.

The canonical continuation branch is `codex/godot-polish-002` in
`rell28194-rgb/yardman`. The local scratch workspace has twice reverted to an
older snapshot. A local commit or a completed agent badge is not a durable save
or proof that an APK exists.

At each tested source milestone, commit only the relevant files, push the branch,
and verify the remote commit's tree matches the local committed tree. Do this
before lengthy rendering, extraction or export. Preserve unrelated work. Never
overwrite the remote branch with an older local snapshot.

The owner-supplied pack and Android signing material are stored separately in
the project's Codex Handoff folder:

| File | Purpose |
| --- | --- |
| Yardman-Personal-Reference-Assets-001.zip | Decoded reference media and hashes; private runtime pack |
| Yardman-Preview-Signing.zip | Stable private preview key and signing configuration |
| Yardman-Personal-Preview-Export-v1.zip | Repeatable staging, export and package verification recipe |
| Yardman-Android-Toolchain-Checkpoint.json | Toolchain and previous fixture evidence |
| CODEX_START_HERE.md | Current state, saved artifacts and remaining work |

Keep private media and signing material outside Git. Save each costly decoded
model immediately before rebuilding the complete asset pack. Keep the same
Library file identity when replacing a pack, using its current version guard.
Save successfully exported APKs, validation reports and actual engine captures
in the project's Builds folder. Record their source commit, byte count and
SHA-256. An exported fixture is not an exported national game.

To recover after a reset, inspect the remote branch before doing new work. Restore
the saved private pack into `godot/assets/user_reference`, restore the exporter
and signing material outside the repository, and regenerate national data with
the compiler commands in `.github/workflows/godot-android.yml`. Generated road,
terrain, coast and building data must all pass their national-data gates.

Import the private project once with Godot, run
`python godot/tools/prepare_reference_assets.py`, and import again. This enables
actual mipmaps on surface textures and keeps WAV loops as exact 16-bit PCM;
Godot's defaults do not satisfy these requirements. Then run the headless and
rendered regressions and save the stable batch. Use the saved exporter recipe
for internal Android validation when needed. Before terminal packaging, run
`python godot/tools/validate_asset_milestone.py --require final_packaging`;
an unfinished recovery ledger blocks final delivery. Inspect and preserve the
package/resources/signature and test evidence for any internal export.

Public CI intentionally tests the asset-absent fallback. The personal export
must separately require and validate the reference media and car. Neither
headless boot nor signed APK validation establishes Android installation,
physical-device performance or visual-quality acceptance.
