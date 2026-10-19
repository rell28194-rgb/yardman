# Yardman execution authority

The owner's latest execution directive governs this existing Godot project:
push tested source, preserve green Android build health, exhaust Beta 1 before
starting Beta 2, and defer final APK delivery until both libraries and their
integration/polish passes are complete. An APK is a checkpoint, never project
completion.

CURRENT PRODUCTION AUTHORITY — DO NOT REGRESS THIS PROJECT TO OLD CI STATE

- The active runtime baseline is the clean map-and-cars reset architecture, not
  any older CI snapshot whose tests expect jobs, traffic AI, pedestrian AI,
  economy systems, placeholder cars, or other retired runtime systems.
- Do not make old tests authoritative over the current game. If an old test
  conflicts with the owner's current production direction, update/retire that
  test instead of reintroducing removed gameplay systems merely to make CI green.
- The full recovered/accepted vehicle fleet is a project-wide requirement. Do
  not collapse Yardman to Crown-only, a legacy sedan, or a tiny test fleet.
  Crown is the default spawn, not the only production car.
- Toyota Mark X is BANNED from Yardman runtime/candidate builds and must not be
  reintroduced by catalog, selector, private pack, fallback, CI fixture, or merge.
- The 992/Porsche path is excluded from production/candidate builds. Do not
  reproduce, badge, relabel, substitute, or ship it.
- A vehicle that fails a quality pass is not automatically deleted from the
  accepted fleet unless the owner explicitly bans/removes it. Improve its
  production quality in the vehicle lane instead.
- Public CI without the private Beta vehicle/media pack is validation-only. A
  fallback/procedural/public-CI vehicle render must never be presented to the
  owner as a representative Beta 1/2 visual candidate.
- Owner candidate builds must compose the current map/reset state with the
  current vehicle-production and graphics/world-quality work. They must fail
  closed if required private hero art or the intended visual stack is absent.
- Jobs/economy, traffic simulation, pedestrian simulation, and AI vehicle-driver
  systems remain disabled unless the owner explicitly reauthorizes them.
- Preserve PR #4 unmerged unless the owner explicitly orders otherwise.

Read `godot/docs/ASSET_EXECUTION.md`, `godot/docs/asset_recovery/ledger.json`
and `godot/docs/RECOVERY.md` before asset work. Do not infer library completion
from a few recovered models, a model-only catalog, successful import, headless
boot, a green public fallback build, or a completed agent badge.

1. Inventory every Beta 1 container and every listed asset category. Recover
   useful families, normalize and test each substantial batch, and document
   deliberate rejections with evidence. Fix foliage atlas alpha, sedan
   triangles/lighting, material translation, scale/orientation, collision,
   road geometry and coastal placement regressions.
2. Save each decoded batch immediately. Commit and push tested source before
   lengthy follow-up work; verify the remote tree. Keep private media and
   signing material outside public Git. Preserve unrelated working changes.
3. Run `python godot/tools/validate_asset_milestone.py --require beta2` before
   fetching or inspecting `beta2.7z.*` contents. A blocked result means continue
   Beta 1. A partial inventory is never evidence that a category is absent.
4. After that gate passes, inventory Beta 2 independently. Classify duplicates
   and prefer measured quality replacements over redundant asset accumulation.
   Import, normalize, render and runtime-check each batch before the next.
5. Keep Android CI green for internal tests. Terminal packaging requires
   `--require final_packaging`; do not deliver a final APK with either library
   or visual/runtime acceptance unfinished.

The user has explicitly authorized parallel agent work. Give agents separate
file ownership and coordinate shared imports, asset pack replacements and Git
publishing. All agents follow the same milestone gates and save discipline.

Keep the entire island of Jamaica, all fourteen parishes, deterministic
EPSG:3448 registration and metre scale. Continue streaming/LOD/origin rebasing;
do not shrink the world, restart in Unity, or reuse pasted credentials. The
owner authorized their supplied assets for the personal game; use that context
without repeatedly asking permission. Report tested outcomes and unresolved
limits plainly. Continue authorized work without asking whether to continue.
