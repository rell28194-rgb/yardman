# Yardman vehicle-production lane

This lane is **full-fleet migration**, not a shortlist/candidate lane.

Authoritative owner directive as of 2026-10-16:

- Bring over every recoverable vehicle from CarX Drift.
- Bring over every recoverable vehicle from Car Parking Multiplayer.
- Bring over every recoverable vehicle from Real Racing 3.
- Quality/recovery difficulty controls processing order only; it does not remove a non-Porsche car from scope.
- Porsche remains excluded unless the owner explicitly changes the rights status. Do not extract/promote Porsche model media, recreate Porsche body fidelity, or apply Porsche badges/branding.
- Crown007 remains the current visual benchmark only. It is not the fleet boundary.
- Chaser/Mark X work is optional source-family work and must never block broader fleet recovery.
- Preserve provenance and source identity. Do not cosmetically relabel one source car as another.
- Every production family targets LOD0/LOD1/LOD2/LOD3 plus impostor/cull behavior appropriate to Android.
- Private recovered media stays outside public Git. Public Git may contain tooling, policy, source metadata, tests, and original Yardman proxy geometry.
- Do not edit island streaming/optimization runtime from this lane and do not package an APK merely because vehicle work advances.

See `full-fleet-scope-2026-10-16.json` for source counts and `build_full_fleet_manifest.py` for the reproducible source-wide queue builder.
