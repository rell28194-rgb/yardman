# Android build recovery — 2026-10-09

The active Godot branch had advanced to `ae5473fcf4fdb4a9fe60b37d2878a89db28872f7` when inspected. The workflow is `.github/workflows/godot-android.yml`, not the older `android-beta.yml` named in the handoff.

Actual failed run: `37969188477`, job `113951140907`, `build-android`. Project import and road-data generation passed. Android export failed because `rendering/textures/vram_compression/import_etc2_astc` was disabled. The logged error explicitly required ETC2/ASTC texture compression for Android export.

The repair enables that project setting. The export preset also explicitly includes road JSON, which is read through FileAccess rather than resource references. CI now boots the actual main scene against the generated national road dataset, waits for physics, and requires a valid vehicle and loaded road tiles. Import/script errors fail the job even if the editor returns a zero exit code. Import, smoke and export logs are preserved on failure. Download progress output was reduced so failures remain readable.

Passing editor import alone does not prove an APK or device launch. Current build results must be taken from the exact commit's CI run and artifact. Geographic terrain remains a separate unfinished layer; the existing broad ground plane is explicitly a temporary driving surface, not a completed Jamaica DEM.
