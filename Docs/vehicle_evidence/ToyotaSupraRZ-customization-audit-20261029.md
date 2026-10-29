# Toyota Supra RZ — source customization audit

Date: 2026-10-29
Source: original CarX Drift Racing 1.16.2 sharedassets0 + original OBB inventory
Yardman ID: `toyota_supra_rz`
CarX PlayerCar ID: `10`
CarX prefab: `ToyotaSupraRZ`
CarX identifier: `supraRZ`

## What is proven

The customization data below comes from original serialized `TextAsset` tables whose object bytes match the exhaustive inventory hashes. It is not reconstructed from screenshots or the old Fleet64 GLB.

Verified source tables:
- `PlayerCars`
- `Profiles`
- `CarProfileParameters`
- `WheelTires`
- `CarColors`
- `GlassColors`
- `SmokeColors`
- `WheelCapDictionaryXML`
- `WheelRimColorsDictionaryXML`
- `WheelSpokeColorsDictionaryXML`

Regeneration tool: `Tools/vehicle_pipeline/recover_carx_customization.py`.

## Default source setup

The original `PlayerCar` record has customization enabled and defines:
- paint/color ID: `91`
- wheel-cap/rim prefab ID: `74`
- rim color ID: `201`
- spoke color ID: `201`
- tyre ID: `10`
- smoke color ID: `91`
- glass color ID: `91`

## Source option counts for PlayerCar 10

- wheel-cap/rim choices: **46**
- tyre choices: **5**
- body paint choices: **13**
- glass color choices: **13**
- smoke color choices: **13**
- rim color choices: **16**
- spoke color choices: **16**
- performance profiles: **5** (`Stock`, `Turbo`, `Racing`, `Drift`, `Ultimate`)

The exact material shader parameters for every color option remain recoverable from the source tables and are intentionally not flattened into a generic RGB picker.

## Tyres

The five source tyre options are not cosmetic. They carry different `frictionMultiplier` values:

| Source ID | UI index | Name | Friction | Durability | Source prefab |
|---|---:|---|---:|---:|---|
| 10 | 0 | Tire1 | 1.00 | 5,000 | `Tires/tire_1L`, `Tires/tire_1R` |
| 58 | 1 | Tire2 | 1.05 | 40,000 | `Tires/Custom/tire_1L`, `Tires/Custom/tire_1R` |
| 106 | 2 | Tire5 | 1.10 | 40,000 | `Tires/Custom/tire_4L`, `Tires/Custom/tire_4R` |
| 154 | 3 | Tire4 | 1.15 | 40,000 | `Tires/Custom/tire_2L`, `Tires/Custom/tire_2R` |
| 223 | 4 | Tire5 | 1.20 | 40,000 | `Tires/Custom/tire_5L`, `Tires/Custom/tire_5R` |

Yardman must preserve this as a physical tyre/grip choice, not only a visual wheel swap.

## Wheel/rim prefab graph

The stock option is source ID `74`, wheel ID `74`, prefab:
`Prefabs/Rims/Stock/ToyotaSupraRZ`

The original Unity member `8368d937e9b203d499bffc164cf9f6f8` contains the stock wheel prefab hierarchy with GameObjects:
- `rim`
- `ToyotaSupraRZ`
- `cap`
- `spokes`

It contains 3 MeshRenderers and 3 MeshFilters plus the original MonoBehaviour component references. The old Yardman hero-GLB route did not preserve this prefab as the authoritative runtime wheel.

The 46 available Supra wheel-cap entries point at source prefabs including:
- `Prefabs/Rims/Stock/ToyotaSupraRZ`
- `Prefabs/Rims/Custom/RZ-Advan832`
- `Prefabs/Rims/Custom/OZBoticelli3`
- `Prefabs/Rims/Custom/MarcelloMR34`
- `Prefabs/Rims/Custom/BBS-SuperRS`
- `Prefabs/Rims/Custom/ForgelineDE3C`
- `Prefabs/Rims/Custom/FZero2`
- `Prefabs/Rims/Custom/VX610`
- `Prefabs/Rims/Custom/HoshinoG5`
- `Prefabs/Rims/Custom/VolkTE37`
- `Prefabs/Rims/Custom/KonigSSM`
- additional BSBS / ZERO DRIFT / RC category rims referenced by the same source table.

These prefab references are recovery targets. A wheel option does not become Yardman-ready until its geometry/material dependency closure is recovered and mounted correctly.

## Performance-profile purchase/upgrade graph

Original CarX profile records for PlayerCar 10:

| Profile | Source profile ID | Source asset | Source identifier | Source cost | Tunable controls |
|---|---:|---|---|---|---:|
| Stock | 37 | `ToyotaSupraRZStock` | `stock` | 0 | 0 |
| Turbo | 38 | `ToyotaSupraRZTurbo` | `gtturbo` | 230,000 | 0 |
| Racing | 39 | `ToyotaSupraRZRacing` | `arcade` | 480,000 | 17 |
| Drift | 40 | `ToyotaSupraRZDrift` | `drift` | 480,000 | 17 |
| Ultimate | 126 | `ToyotaSupraRZUltimate` | `ultimate` | premium-source cost | 30 |

The Racing/Drift tuning panels expose source parameters including spring travel/stiffness, toe, camber, caster, Ackerman, disc diameter, tyre width/pressure and brake balance. Ultimate additionally exposes the broader source tuning controller set. The parameter IDs/ranges are recoverable from `Profiles` + `CarProfileParameters` and should map to actual Yardman physics, not decorative sliders.

The five profile XML payloads themselves contain source mass, transmission, differential, torque/RPM, turbo, brakes, suspension and aero values. These are already grounded in `godot/data/vehicles/toyota_supra_rz/vehicle.json` as source evidence. A validated CarX→Yardman physics mapper is still required before runtime promotion.

## Body-kit scope clarification

A search of the original CarX 1.16.2 `TextAsset` customization databases and managed runtime symbols shows the normal customization path centered on paint/glass/smoke, wheel caps, tyres, rim/spoke colors and car profiles/tuning. No ordinary `BodyKit`/hood/spoiler/bumper database was found for the standard Supra record in this build.

Therefore Yardman must reproduce the source customization actually present. It must not invent body-kit parity that this source version does not demonstrate. Separate custom/livery vehicle prefabs found elsewhere in the source are separate vehicle/variant families unless a source compatibility relationship is proven.

## Remaining source closure

Before the Supra can move from `DISCOVERED` toward `RECOVERED`:
- recover geometry/material dependencies for the stock wheel prefab and the desired 45 alternate wheel prefabs;
- recover the five tyre prefab families;
- map source paint/glass/rim/spoke material parameters into Godot shaders;
- reconstruct the source vehicle hierarchy rather than using only the flattened hero GLB;
- recover vehicle-specific audio event/bank relationships;
- map source collision hierarchy;
- validate a physics translation for the five source profiles and tuning-controller ranges.

## Self-critique

This audit proves the source option graph and source tuning breadth. It does **not** prove that every option already has a recovered Godot asset or that the old Fleet64 Supra can render these choices. Those are still blocking integration gates and are deliberately kept unresolved in the runtime definition.
