# RDX Stream Recovery Promotion Evidence

Date: 2026-10-18

Status: PROMOTION CANDIDATE
Confidence: 94/100

## Production-derived base

Base branch: `codex/world-quality-20261018`
Base SHA at promotion fork: `0d5dbbc7a68a8fd4a948eb583fdac4f0887c630e`

Promotion branch: `codex/rdx-stream-recovery-promotion-001`
Runtime fix commit: `e1f286a20709ca81476db2fc41da5b11c918c8d3`
Validation commit: `97c72e0187efbd0e894be302b544863636c5c5cf`

## Defects reproduced and fixed

1. A tile that had successfully loaded could remain in the failed set until its previous retry deadline, allowing stale failure state and a later unnecessary refresh.
2. Retry-attempt history could remain orphaned after a released failure later left the wanted set, retaining stale backoff state.

The promoted policy now:
- reconciles loaded tiles by clearing both failure state and attempt history;
- records `loaded_failures_cleared` separately from normal retry releases;
- removes orphaned attempt history for keys no longer wanted;
- records `stale_attempts_dropped` separately from active stale failures;
- preserves existing retry-release and stale-failure metric semantics.

## Deterministic oracle

The production-derived Godot 4.7.2 project imported cleanly and the adversarial retry suite passed:

- schema rejection for malformed/LLM-proposed actions;
- deterministic scenario replay;
- exponential backoff schedule and 30 s cap;
- repeated-failure attempt progression;
- exact retry-deadline behavior;
- stale failure cleanup;
- orphan attempt-history cleanup;
- legacy boolean failure conversion;
- loaded/failure reconciliation;
- metric-accounting checks.

GitHub Actions run: `39172540484`
Result: success

## Mutation score

Curated semantic mutation gate: 18 valid mutants
Killed: 18
Survived: 0
Invalid: 0
Mutation score: 1.0000 / 100%
Required score: 1.0000

Mutations covered realistic regressions in:
- backoff indexing;
- backoff disablement;
- retry cap;
- attempt incrementing;
- immediate deadlines;
- category preservation;
- loaded attempt cleanup;
- loaded failure cleanup;
- loaded cleanup telemetry;
- exact-boundary comparison;
- due-failure removal;
- release telemetry;
- stale failure cleanup;
- stale failure telemetry;
- orphan attempt cleanup;
- orphan cleanup telemetry;
- active-failure accounting;
- legacy retry timing.

## Confidence grade

94/100.

Why not 100:
- correctness is strongly evidenced in deterministic Godot 4.7.2 CI and mutation testing;
- the patch is narrow and production-derived;
- no physical Android device soak has yet exercised repeated I/O failure/recovery under thermal and storage pressure.

This score is component-specific. It does not imply 94/100 confidence in the entire Yardman streaming stack.

## Promotion recommendation

The runtime fix is suitable for integration into the active world-quality lane once rebased/cherry-picked onto its latest head and normal branch contracts remain green. Preserve the adversarial and mutation gates so future edits cannot silently reintroduce these state-machine failures.
