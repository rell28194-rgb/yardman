# Yardman execution authority

The owner's latest execution directive governs this existing Godot project:
push tested source, preserve green Android build health, exhaust Beta 1 before
starting Beta 2, and defer final APK delivery until both libraries and their
integration/polish passes are complete. An APK is a checkpoint, never project
completion. Continue from the newest production-derived Yardman branch; never
revive an older runtime merely because its historical tests are easier to pass.

## Owner runtime contract — project-wide

This contract overrides obsolete gameplay/test assumptions everywhere in the
repository and across future agents/branches unless the owner explicitly changes
it.

- Runtime scope is **map + cars + world/graphics systems**. Do not reactivate
  jobs/economy, courier gameplay, NPC/pedestrian simulation, autonomous traffic
  gameplay, or other removed legacy systems just to satisfy an older test.
- Existing dormant source may remain for provenance/history, but it must not be
  autoloaded or become a dependency of the active owner runtime.
- Vehicle selection must not depend on `JobRuntime`, `JobPersistenceRuntime`, a
  wallet, prices, job progress, or economy state.
- **Toyota Mark X is banned from Yardman production/runtime.** Do not expose,
  spawn, select, package, restore, substitute, or reintroduce it from historical
  branches, saved selections, tests, recovered packs, or fallback logic.
- The former 992/Port Royal 992 path is excluded from the owner vehicle build.
  Do not restore it through historical tests or fallback logic.
- The recovered fleet registry/data from the vehicle-production lane is a
  required production input. Integrate the other recovered vehicles when their
  verified private source media are present; do not collapse the owner build
  back to Crown-only because public CI lacks private media.
- Toyota Crown remains an accepted owner vehicle source, subject to the same
  private-pack verification and visual/runtime acceptance as the recovered
  fleet.
- Public CI that omits owner-private vehicle media is **not** visual/vehicle
  acceptance evidence and must never be handed to the owner as a representative
  Beta vehicle build. Owner APK export must fail/withhold candidate status when
  required private hero vehicle media are absent rather than silently showing a
  procedural/legacy fallback.

## Validated graphics / R&D promotion contract

Preserve and use graphics work only according to its measured promotion state.
The validated RDX promotion lane is production ancestry, not disposable test
work.

- Preserve the accepted renderer/material capability contract from
  `codex/validated-rdx-promotion-20261018` / validated head
  `64c8242bd9887a464bbeacb8d978cd36c6291c61`.
- Keep Compatibility as the desktop/headless validation baseline and Mobile /
  Vulkan as the Android mobile renderer path. Do not perform a speculative
  engine or renderer-policy switch.
- Preserve `render_quality_manager.gd`, `render_material_registry.gd`, the
  renderer-specific road/water/terrain material families, adaptive resolution,
  thermal/frame-pacing policy, shared streaming integration budgets and shadow
  budget policy that passed the renderer capability/fallback validation.
- The passed renderer contract proves correct backend/material selection and
  fallback behavior. Do not claim hosted llvmpipe results prove physical-phone
  performance.
- RDX-003 conservative HZB and RDX-004 cluster/meshlet work remain research-only
  until their outstanding production/device evidence is satisfied. Do not
  silently promote them merely because their research gates were green.
- Missing Godot capabilities may still be developed in isolated R&D lanes; only
  promote them after measurable success and regression review against the
  current production state.

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

## Production-data and placeholder rule

Missing production content is an execution task, not permission to invent a
substitute. If required world data, assets, compiled packs, metadata, tools, or
runtime artifacts do not exist, trace the declared source and build/acquisition
pipeline and create the real artifact with provenance. Do not silently fill a
production gap with synthetic geometry, fake geography, guessed measurements,
placeholder art, fabricated source records, or test data.

Synthetic fixtures remain allowed only inside clearly named tests and isolated
validation harnesses. They must be explicitly marked `fixture`, `synthetic`, or
`test-only`; they must not be packaged as production data, counted as visual or
geographic acceptance evidence, or used to claim that a missing real layer is
complete. Production acceptance requires the real source-derived/private asset
path appropriate to that subsystem plus its provenance and runtime validation.

When a source is public, preserve its URL/provider, source hash, attribution,
coordinate/datum information, compiler version/commit, and output manifest. When
a source is owner-supplied/private, preserve the existing private provenance
ledger and keep restricted media outside public Git. If a real source cannot be
acquired or legally used, report the gap plainly and leave the production layer
incomplete rather than disguising it with a placeholder.

The user has explicitly authorized parallel agent work. Give agents separate
file ownership and coordinate shared imports, asset pack replacements and Git
publishing. All agents follow the same milestone gates and save discipline.

Keep the entire island of Jamaica, all fourteen parishes, deterministic
EPSG:3448 registration and metre scale. Continue streaming/LOD/origin rebasing;
do not shrink the world, restart in Unity, or reuse pasted credentials. The
owner authorized their supplied assets for the personal game; use that context
without repeatedly asking permission. Report tested outcomes and unresolved
limits plainly. Continue authorized work without asking whether to continue.
