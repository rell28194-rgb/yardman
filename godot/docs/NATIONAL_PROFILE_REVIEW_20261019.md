# National profile review — 19 October 2026 UTC

Verified live world head: `64c8242bd9887a464bbeacb8d978cd36c6291c61`.

The handoff validation debt is resolved: [production run 39173528834](https://github.com/rell28194-rgb/yardman/actions/runs/39173528834) completed successfully on compiler `003fda123b7c8cf901379e7a135a16017820deec`. The five road/terrain compiler and audit files were byte-identical to the verified world head. The workflow already has `cancel-in-progress: false`; no concurrency change or redundant national rebuild was needed.

Artifact 12153644236 was downloaded and its graph shards and terrain samples inspected. Machine-readable evidence is in `production_evidence/national-profile-refinement-20261019.json`. It includes source hashes, exact worst segments for every highway class, and terrain samples around the three largest grade breaks.

## Same-source comparison

Both builds used the same OSM SHA and all five identical Copernicus COG hashes. Earlier run: 39155404062. Later run: 39173528834.

| Metric | Earlier compiler | Refined compiler |
| --- | ---: | ---: |
| Grade p95 (%) | 21.3357 | 15.3430 |
| Grade p99 (%) | 34.6128 | 23.9690 |
| Maximum grade (%) | 92.6317 | 68.9345 |
| Segments above 20% | 49,250 | 17,136 |
| Grade-break p95 (percentage points) | 14.8027 | 2.9655 |
| Maximum grade break (percentage points) | 130.9612 | 65.2664 |

Coverage: 120,412 graph edges, 101,656 nodes, 1,023,152 buildings, 63,200 building cells, 2,261 places and all 14 canonical parishes. This is compiler/coverage evidence, not visual or device acceptance.

## Remaining source-level limits

The worst track segment (`w1338933288`, a two-point graph edge) has a 68.9345% grade in both the road and runtime terrain. Its endpoints were preserved as intended. Smoothing cannot change this two-point profile without changing its source constraints.

The worst primary-road segment (`w50438408`) has 34.6675% deck grade against 88.3325% terrain grade. Its two deck corrections reach opposite sides of the existing ±6.4 m envelope. The worst motorway segment (`w573251948`) remains at 21.3523% after reducing the local terrain grade of 33.9004%. The three largest residual grade breaks also reach the correction envelope at their central vertices.

These measurements identify a coarse DSM / road-alignment constraint, not proof that the actual roads have those grades. Increasing the envelope or clamping grades would hide the unresolved source issue. Next geographic work should inspect original COG samples, OSM structural tags and road alignment at these exact source ways, then validate a source-backed vertical reconstruction. No production geometry was rewritten in this review.

## Runtime continuation

Road integration previously appended both material mesh uploads and tile publication to the CPU geometry slice. The staged fix separates CPU preparation, paved upload, dirt upload and publication, including intermediate 2,048-record batches. A deterministic test covers actual mesh arrays, signal ordering, surface-query preservation and teardown during partial upload. This bounds combined phases, but a single upload remains indivisible and still needs Android timing evidence.
