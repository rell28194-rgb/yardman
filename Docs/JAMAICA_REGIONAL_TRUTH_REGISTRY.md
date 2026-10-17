# Yardman Jamaica Regional Truth Registry

Status: evidence ledger and implementation constraints for the 1:1 Jamaica world. This file is not a visual-style guide. It exists to prevent generic terrain, hydrology, structures, vegetation and infrastructure from replacing regional source truth.

## Evidence precedence

1. Exact surveyed/GIS/source geometry and official agency records.
2. Jamaica government hydrology, geology, land-cover, protected-area and infrastructure datasets.
3. OSM geometry/tags for locally registered features, with confidence recorded.
4. DEM-derived slope/elevation/landform evidence.
5. Regional grammar only where exact local evidence is absent; never use it to override contradictory source data.

Any inferred cut, embankment, channel width, foundation treatment, vegetation mix or structural form must remain distinguishable from source evidence.

## Authoritative source families

### Water Resources Authority — hydrology

Primary reference: Water Resources Authority, *A National Water Resources Master Plan for Jamaica 2022*.
https://www.wra.gov.jm/wp-content/uploads/2024/09/A-National-Water-Resources-Master-Plan-for-Jamaica-2022.pdf

Implementation constraints:
- Organize hydrologic context by the official twenty-six Watershed Management Units rather than parish alone.
- Use WRA hydrologic/floodplain information when available to supersede generic drainage inference.
- Keep river, stream, gully, wetland, floodplain and groundwater/karst behavior separate; administrative parish boundaries are not hydrologic boundaries.

### Mines and Geology Division — geology / engineering geology

Primary landing reference:
https://mgd.gov.jm/geology-of-jamaica/

Quarry/mineral occurrence cross-check:
https://mgd.gov.jm/quarry-licensing/

Implementation constraints:
- Road cut faces, exposed rock, retaining conditions, quarry scars and erosion style require mapped geology/topography or explicit local evidence.
- Do not use one island-wide rock material.
- Recorded river-sand/aggregate locations along rivers such as the Rio Minho, Yallahs, Morant, Plantain Garden, Rio Grande, Wag Water and others are useful evidence of active alluvial channel character, but are not permission to alter an entire river uniformly.

### Forestry Department — 2023 land cover

Primary reference: *State of Jamaica's Forests: A Comparative Assessment of Forest Change between 2013 & 2023*.
https://www.forestry.gov.jm/resourcedocs/State_of_Jamaica_s_Forests_Report_2024-1.pdf

Verified national constraints from the report:
- 2023 forested land cover: 527,394.51 ha, about 48% of the island.
- Mainland forest cover: 47.9%.
- Secondary forest is the largest forest category.
- 2023 mapped mangrove forest: 14,843.27 ha; the report warns that the increase versus 2013 primarily reflects improved field mapping/reclassification rather than true expansion.

Implementation constraints:
- Vegetation density/type must follow mapped land cover where available.
- Distinguish secondary forest, closed/disturbed broadleaf, mangrove, wetland, agricultural/open land and urban tree cover rather than applying generic tropical vegetation.

### NEPA — wetlands / protected coast / sensitive landscapes

Protected-area reference:
https://www.nepa.gov.jm/protected-areas-2

State of Environment reference:
https://www.nepa.gov.jm/sites/default/files/2019-12/SoE_Jamaica_2013.pdf

Implementation constraints:
- Black River Lower Morass and Negril Great Morass require wetland/mangrove/swamp/marsh treatment, not ordinary dry terrain plus scattered palms.
- Palisadoes-Port Royal and Portland Bight require coastal wetland/mangrove/shallow-water context where locally supported.
- Protected-area identity must constrain asset/vegetation/coast generation rather than merely provide labels.

### National Works Agency — bridges / culverts / road structures

Bridge database:
https://www.nwa.gov.jm/nwa-bridges

The NWA records parish, bridge name, control-section description, span and superstructure type. Records include concrete/steel girders, trusses, arches, rigid frames, slabs and box culverts.

Implementation constraints:
- Named/identifiable bridges should resolve against NWA records before assigning a structural family.
- A mapped road/water crossing must not automatically become a generic bridge. Check source bridge/ford/culvert/layer evidence and, where identifiable, NWA structure type/span.
- Underpasses and box culverts must remain distinct from river bridges and tunnels.

## Initial regional physical-truth cases

These are implementation scopes, not texture presets. Exact local GIS evidence still wins.

### Kingston / St. Andrew
- Dense urban road/building relationship and engineered gullies/drainage require separate handling from rural river corridors.
- Palisadoes-Port Royal is a protected coastal/wetland context and must not inherit ordinary urban shoreline treatment.
- Mountain approaches north/east of the basin require slope-aware cut/fill and retaining logic rather than road ribbons draped over the DEM.

### St. Catherine / Rio Cobre corridor
- Validate road/rail/river structure crossings against hydrology and NWA structure evidence.
- Bog Walk is explicitly recorded by MGD as an alluvial-deposit location; use mapped geology before deciding exposed cut/fill material.

### Clarendon / Rio Minho
- Rio Minho corridors need alluvial/channel morphology where evidenced; MGD records active river-sand/aggregate extraction at multiple Rio Minho locations.
- Portland Bight coastal/wetland context affects the southern parish edge and must differ from inland limestone/upland terrain.

### St. Elizabeth / Black River
- Black River Lower Morass is a major freshwater wetland/mangrove/swamp/marsh system and must be implemented as a hydrologic landscape, not a narrow river ribbon.
- MGD records alluvial deposits in Black River Valley and other St. Elizabeth lowland locations; exact mapped units should drive terrain/material decisions.

### Westmoreland / Negril
- Negril Great Morass requires wetland hydrology, low relief and vegetation logic distinct from adjacent limestone/coastal terrain.
- NWA records numerous river/gully bridges and culverts in Westmoreland; structure family should be record-driven where matched.

### St. Thomas / eastern river valleys
- Yallahs, Morant and Plantain Garden river corridors have strong official evidence for active river aggregate systems and numerous NWA crossings.
- Preserve steep mountain-to-coast drainage gradients and do not normalize them to the broad lowland river profile used in western wetlands.

### Portland / St. Mary
- Wet north/east mountain drainage, named river corridors and steep terrain require channel, bridge and cut/fill integration.
- MGD records river aggregate activity along the Rio Grande and Wag Water; use as local geomorphic evidence only where spatially matched.

### St. Ann / Trelawny / Cockpit and limestone interiors
- Karst/limestone context requires sink/depression/underground-drainage awareness where authoritative evidence exists; do not fabricate caves or sinkholes from a generic limestone flag.
- Mason River wetland context spans Clarendon/St. Ann and demonstrates that upland wetland/depression behavior cannot be inferred from coast distance alone.

### Hanover / St. James
- Western limestone/coastal terrain and river/gully crossings need record-backed structural treatment.
- NWA bridge records show a mix of concrete/steel girders, rigid frames, arches and box culverts; do not collapse them into one bridge mesh family.

### Manchester
- Interior upland/limestone and bauxite-affected landscapes require geology/land-use evidence before exposing rock, excavation or quarry-like ground.

## Required generated-data layers

The production compiler should progressively expose the following registered layers:
- parish boundary/context;
- watershed/WMU context;
- source waterway centerline and waterbody/wetland geometry;
- DEM elevation/slope/relief;
- geological/engineering-geology unit when available;
- 2023 land-cover class when available;
- protected-area/wetland/coastal context;
- road structure/crossing classification;
- building reconstruction confidence and terrain/foundation condition.

No visual system should need to guess a regional identity from parish name alone once these layers are available.
