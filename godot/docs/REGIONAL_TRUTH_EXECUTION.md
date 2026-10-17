# Yardman Regional Truth Execution

Status: canonical map/world execution requirement for `codex/map-cars-reset-001`.

## Non-negotiable world rule

Yardman is not a terrain surface with roads, buildings, bridges, tunnels, rivers and vegetation pasted on top. Every visible world system must either be source-registered to the physical landscape or be explicitly marked as conservative presentation inference.

Parishes remain the administrative/navigation layer. Physical reconstruction uses a second hierarchy:

1. hydrologic basin / watershed management unit,
2. geology / engineering-geology context,
3. elevation, slope and landform,
4. land cover / wetland / coast class,
5. settlement and road context,
6. parcel/building source evidence.

No single Jamaica-wide visual preset may erase these regional differences.

## Authoritative source stack

Use the strongest available evidence first and retain provenance in generated manifests.

- Water Resources Authority: 10 hydrologic basins, 26 Watershed Management Units, perennial-river and streamflow context. Primary references include the National Water Resources Master Plan for Jamaica 2022 and Water Quality Atlas 2019.
- Mines and Geology Division: regional geological mapping, engineering geology, rock/soil context, landslide/earthquake mapping and geotechnical evidence.
- Forestry Department: 2023 land-use/land-cover truth and forest/wetland/mangrove classifications.
- NEPA: watershed, protected-area, wetland, coastal, beach and environmental-management evidence.
- National Works Agency: bridge inventory, road classifications, road/bridge construction records, drainage/gully and flood-control context.
- OpenStreetMap/Geofabrik: registered roads, waterways, bridges, tunnels, buildings, building parts and tagged structure semantics.
- Yardman DEM/terrain source stack: elevation truth used for registration and measured slope/relief.
- Project-owned/reference imagery and verified recovered assets: presentation/detail only; never override stronger GIS/source geometry.

## Regional reconstruction units

The implementation must support overlapping physical regions, not only parish boundaries. Minimum first-pass units:

- Blue Mountain South: St. Thomas, including Plantain Garden, Morant and Yallahs systems.
- Kingston basin: Kingston/St. Andrew, Hope River and urban gully/drainage systems.
- Rio Cobre basin: St. Catherine corridors and associated valleys/plains.
- Rio Minho basin: Clarendon/Manchester plains, uplands and drainage transitions.
- Black River basin: St. Elizabeth riverine lowlands, wetlands, mangroves and coastal transitions.
- Cabarita basin: Westmoreland river/coast systems.
- Great River basin: St. James/Hanover drainage and western coastal terrain.
- Martha Brae basin: Trelawny river/karst context.
- Dry Harbour Mountains basin: St. Ann limestone/karst context.
- Blue Mountain North: St. Mary/Portland wet mountain drainage, Rio Grande and related north/east rivers.
- Cockpit Country: karst relief spanning relevant western/central parishes; treat as a physiographic override rather than a parish preset.
- Negril/morass coast: wetland/coastal override.
- Portland Bight: coastal/wetland/limestone/industrial-settlement override where source evidence supports it.
- Blue and John Crow Mountains: steep wet mountain/forest override spanning parish boundaries.

These are starting execution units, not permission to simplify local differences inside them.

## Buildings versus roads

A source footprint does not automatically have permission to occupy the carriageway.

For every building mass and building part:

- test ground-origin footprint against the classified drivable road corridor;
- test source/inferred roof overhang independently from the footprint;
- preserve legitimate zero-setback roadside buildings when they do not enter the carriageway;
- preserve explicit elevated building passages/bridges where source evidence supports them;
- reject or clip invalid road intrusion and retriangulate the final roof against the repaired footprint;
- do not translate the road network to hide bad building geometry;
- on slopes, derive foundation relief from sampled terrain and require a believable pad, stepped base, pier/column condition or retaining treatment rather than a floating shell.

National acceptance must report adjusted buildings, unresolved conflicts, removed area, elevated/grade-separated exclusions and roof rebuild failures.

## Roads: cut, fill and retaining conditions

Road geometry must interact with the terrain.

For each registered road corridor, compare road profile against surrounding DEM cross-sections and classify only when evidence is strong enough:

- terrain-conforming road,
- cut into slope,
- fill/embankment,
- retaining-supported edge,
- bridge approach,
- tunnel approach,
- ford/culvert/river crossing where sourced.

Cut sections must remove/intersect terrain visually and physically and expose a regionally appropriate rock/soil face based on geological context. Fill sections need embankment geometry instead of a floating ribbon. Do not fabricate dramatic rock cuts where slope/source evidence does not support one.

## Bridges

A bridge is a crossing structure, not an elevated road decal.

Required model:

- source road centerline and layer semantics;
- registered abutments on both ends;
- terrain-independent deck grade between source-backed control points;
- terrain/water/gully remains below the deck;
- piers only where span/type/source evidence warrants them;
- approach cut/fill/retaining condition connects the deck to the surrounding road;
- crossing target must be classified when possible: river, stream, gully, road, rail or terrain ravine;
- NWA bridge inventory may provide bridge name, span and superstructure class for identifiable matches.

## Tunnels

A tunnel is a terrain bore, not a shell placed on the mountain.

Required model:

- source tunnel/layer semantics;
- DEM-registered portal locations and approach grades;
- portal opening actually removes visual and collision terrain;
- road grade continues below terrain through the bore;
- interior shell hides the heightfield underside;
- portal approach includes source-backed cut, retaining or rock face treatment;
- no visible terrain wall across the travel opening;
- no tunnel generated for ambiguous covered-road/building-passage tags until classification is resolved.

Long term, portal and approach deformation should be compiled into terrain masks/patch geometry rather than relying only on runtime masking.

## Rivers, streams, gullies and wetlands

Hydrology must become a first-class national layer.

Compile source waterways and assign hydrologic context. At minimum preserve:

- name and OSM identity,
- waterway type,
- perennial/intermittent evidence when available,
- hydrologic basin and WMU,
- terrain longitudinal profile,
- local valley/channel cross-section,
- road/bridge/culvert intersections,
- coastal/estuary outlet relation,
- wetland/mangrove context where present.

Rendering rules:

- water surfaces sit inside a terrain channel, not on top of unmodified land;
- channel/bank width follows source evidence where present and conservative class inference otherwise;
- Blue Mountain rivers may use steep confined rocky channels where slope/geology supports it;
- Black River/wetland systems require low-gradient floodplain/wetland treatment;
- north-coast karst drainage, springs and disappearing/short streams must not be forced into the same grammar as mountain rivers;
- Kingston/St. Andrew gullies/drains require urban drainage treatment where source/agency evidence supports it;
- mangrove, swamp and estuarine transitions must follow land-cover/coastal evidence.

## Geological and landform expression

The renderer must consume a regional geological/physiographic classification before choosing exposed terrain materials or rock geometry.

Examples of permitted evidence-driven variation:

- limestone/karst: solutional relief, exposed pale limestone, sink/karst landform context where mapped;
- volcanic/metamorphic/shale mountain terrain: steeper weathered rock/soil cuts where mapped and slope supports exposure;
- alluvium/floodplain: low-relief depositional terrain, riverbanks and wetland transition;
- coastal sand/rock/mangrove: distinct shore geometry/material families;
- engineered road cuts/quarries: only from source evidence or unmistakable terrain/imagery evidence.

Geology determines allowable material/shape families. It must never invent a specific cliff, cave or quarry without positional evidence.

## Built-form deep dive

For every parish and major settlement/subregion, maintain an evidence-backed profile covering:

- density and street relationship,
- setbacks and building lines,
- roof geometry/material families,
- wall/cladding families including masonry, timber and corrugated metal/zinc,
- veranda/porch and extension patterns,
- slope adaptation and retaining walls,
- fences, gates and boundary walls,
- roadside shops/commercial frontage,
- drainage/gullies/ditches,
- utility poles/wires and roadside infrastructure,
- civic, school, church, resort, industrial and commercial structure classes,
- vegetation/yard relationship.

Use hierarchy: national Jamaica base -> physical region -> parish -> settlement -> local/source override. Missing evidence is not permission to hallucinate precision.

## Acceptance captures

Every material milestone should capture fresh views for at least:

- dense settlement/road/building relationship,
- steep road cut or mountain corridor,
- bridge plus crossing beneath it,
- tunnel portal and approach,
- river/stream channel,
- wetland or mangrove/coastal transition,
- beach/rocky coast,
- rural vegetation,
- wide atmospheric view.

Grade geographic credibility, terrain integration, building placement, road/building relationship, bridge/tunnel integration, hydrology, regional geology, vegetation, coast/wetland, material cohesion and visible artifacts. Overall >= 8.0/10 and every critical structural category >= 7.5/10 are required for visual acceptance.

## Immediate implementation order

1. Finish national building/road conflict validation, including overhang/part/foundation cases.
2. Add a terrain-earthworks compiler for road cut/fill and bridge/tunnel approaches.
3. Add national hydrology compiler and runtime streamer using WRA/OSM context.
4. Add regional truth registry joining parish + basin/WMU + geology + land cover + slope/elevation + settlement.
5. Drive exposed rock, river, vegetation, coast and built-form grammars from that registry.
6. Rebuild multi-angle acceptance captures and iterate until the terrain no longer reads as a surface with objects pasted on top.
