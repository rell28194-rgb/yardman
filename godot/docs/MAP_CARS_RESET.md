# Yardman Map + Cars Reset

This branch intentionally returns Yardman to the clean pre-AI world baseline.

## Active scope

1. Full-island Jamaica map at the existing geographic scale.
2. Roads, terrain, coastline, bridges/tunnels and registered buildings.
3. Visual quality: terrain materials, building materials/facades, lighting, water, vegetation, atmosphere and camera presentation.
4. Player traversal needed to inspect the world.
5. Vehicle work only after the map is visually accepted. Dedicated vehicle-production branches may be integrated selectively after that point.

## Explicitly out of scope

- Traffic AI.
- Pedestrian AI.
- NPC simulation.
- Jobs/economy.
- Ambient simulation systems that do not directly improve map or vehicle presentation.
- Reintroducing the later performance/streaming experiment stack wholesale.

## Baseline

The branch was reset from commit `db85c953dc472a16ac38ab8d488c97f8217499c7` (`feat: attach recovered facade modules to streamed registered walls`). That baseline already contains sourced coastline geometry, registered streamed buildings, road structures and facade support without the later traffic/NPC/job stack.

## Rule

Do not merge later systems back into this branch just because they exist elsewhere. Every addition must answer one of two questions: does it make the Jamaica map look better, or does it make an accepted vehicle look better/play better? If not, it stays out.
