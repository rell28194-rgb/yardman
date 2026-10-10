# Original terrain and vegetation polish

The terrain uses an original procedural RGB noise texture shared across tiles,
triplanar detail, larger grass/soil patches and a broad regional color blend.
Steeper triangles expose stone. All scale bands use canonical coordinates;
render-origin shifts do not move their appearance. The shader precision wrap
is divisible by each texture repeat interval, including 16 km tile boundaries.
Height and surface collision remain the compiled DEM, with no cosmetic vertical
compression. The palette is a visual approximation, not surveyed land cover.

Original palm meshes have curved ringed trunks, curved frond ribs and folded
leaflets. Higher elevations use branched broadleaf canopies. Shrubs and nearby
grass provide additional ground layers. Plants use deterministic road-derived
seeds and actual terrain heights. A spatial index checks all nearby road
carriageways before planting, rather than only the road that proposed a plant.
Missing/NaN height data and sea-level samples produce no plants.

Vegetation is grouped into 256 m cells by species. Trees and shrubs cull at
different distances; grass culls at 150 m. Quality profiles alter deterministic
instance prefixes and shadow choices, preserving a vegetation layer at every
tier. These meshes are original project code. They contain no reference-game
assets. The regional drought palette and proxy planting still need replacement
with licensed land-cover data as fidelity grows.

The brighter natural daylight setup includes a blue sky, distant atmospheric
haze, warm sunlight and ambient fill. Day/night updates change actual lights
and sky colors. Mobile Compatibility rendering is the required target;
desktop software rendering is useful for visual inspection, not a phone
performance measurement.

Validation: `godot --headless --path godot --script res://tests/visuals_test.gd`.
This checks canonical material coordinates, shared textures, daylight, terrain
placement, crossing-road exclusion, culling groups, custom quality and missing
terrain. A render is still required to assess actual appearance.
