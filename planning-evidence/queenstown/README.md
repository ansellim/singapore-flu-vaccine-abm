# Queenstown real-geography inputs

Public inputs for the Queenstown planning-area extension of the influenza ABM (URA Master Plan 2019 geography, Census of Population 2020). AI agents downloaded, geocoded and documented these files on 2026-11-19. No model code is in this folder. Every file `X.ext` has a sidecar `X.source.json` that records the exact source URL, the retrieval date, the rows or features, the sha256 of the stored file, and the file's purpose. Raw files are stored exactly as downloaded. Files whose names end in `-derived` were made by the scripts listed below, and their sidecars record the inputs (with sha256), the script and the exact method.

## Scripts (model/scripts/data/)

| Script | What it does |
|---|---|
| `download_queenstown_inputs.py` | Downloads every raw file. GeoJSON and CSV files come from the data.gov.sg `poll-download` endpoint, which returns a signed URL valid for one hour that is then fetched. Census tables come from `datastore_search` with `limit=10000`. Writes the sidecars. Rerunnable; files already on disk are skipped. |
| `geocode_queenstown_inputs.py` | Geocodes HDB blocks, MOE schools and supermarkets with the OneMap search API. Raw responses are cached outside the project, in the session scratchpad. Writes the `*-geocoded-derived.csv` files. Match rules are in the script docstring. |
| `build_queenstown_geography.R` | Uses sf to reproject everything to EPSG:3414 and clip it to Queenstown. Writes the `queenstown-*-derived.*` files. |

Rebuild order (run from the repository root):

```
python3 -I model/scripts/data/download_queenstown_inputs.py planning-evidence/queenstown
python3 -I model/scripts/data/geocode_queenstown_inputs.py planning-evidence/queenstown <cache_dir> hdb=QT,BT,CL,BM "schools=BUKIT BATOK,BUKIT MERAH,BUKIT TIMAH,CLEMENTI,JURONG EAST,QUEENSTOWN,RIVER VALLEY,SINGAPORE RIVER,NEWTON,ORCHARD,TANGLIN,SOUTHERN ISLANDS,WESTERN ISLANDS" supermarkets
Rscript model/scripts/data/build_queenstown_geography.R planning-evidence/queenstown
```

`mp2019-land-use.geojson` (174 MB) is listed in `.gitignore`. The download script recreates it, and its sidecar keeps the sha256 so a fresh copy can be checked against the version used here.

## Raw files

Dataset pages are `https://data.gov.sg/datasets/<id>/view`. For the poll-download files, the source is `https://api-open.data.gov.sg/v1/public/api/datasets/<id>/poll-download`. For the Census tables, it is `https://data.gov.sg/api/action/datastore_search?resource_id=<id>&limit=10000`. All were retrieved on 2026-11-19.

| File | Dataset (id) | Rows / features | Use | Caveats |
|---|---|---|---|---|
| `mp2019-subzone-boundary-nosea.geojson` | Master Plan 2019 Subzone Boundary (No Sea) (d_8594ae9ff96d0c708bc2af633048edfb) | 332 | Subzone polygons; joins Census subzone tables | WGS84 with a Z coordinate; reprojected in the derived files |
| `mp2019-planning-area-boundary-nosea.geojson` | Master Plan 2019 Planning Area Boundary (No Sea) (d_4765db0e87b9c86336792efe8a1f7a66) | 55 | Official Queenstown boundary used for clipping | Not in the original request; added so the boundary does not depend on dissolving subzones |
| `mp2019-land-use.geojson` | Master Plan 2019 Land Use layer (d_90d86daa5bfaa371668b84fa5f01424f) | 113,213 | Island-wide land-use zoning | 174 MB and git-ignored. This is planned zoning, not current use. |
| `hdb-property-information.csv` | HDB Property Information (d_17f5382f26140b1fdae0ba2ef6239d2f) | 13,392 | Block-level dwelling units by flat type | Current stock (last updated 2026-10), not 2020. There is no postal code or coordinate column. Blocks are grouped by HDB town (`bldg_contract_town`), not by URA planning area. |
| `moe-general-information-of-schools.csv` | General information of schools (d_688b934f82c1059ed0a6993d2a829089) | 337 | School list with postal code, `mainlevel_code` and `dgp_code` (planning area) | MOE schools only; there are no international or private schools. Current list (2026), not 2020. |
| `ecda-preschools-location.geojson` | Pre-Schools Location (d_61eefab99958fd70e6aab17320a71f1c) | 2,290 | Preschool locations | The only attributes are centre name and code, held in a Description HTML table. There is no capacity or childcare versus kindergarten type. Data are from 2021 (FMEL_UPD_D). |
| `nea-hawker-centres.geojson` | Hawker Centres (GEOJSON) (d_4a086da0a5553be1d89383cd90d07ecd) | 129 | Hawker centre locations | `STATUS` includes "Under Construction"; filter it if needed |
| `pa-community-clubs.geojson` | Community Clubs (d_f706de1427279e61fe41e89e24d440fa) | 125 | Community club locations | Dated 2021. A newer dataset, "Community Club / PAssion WaVe Outlet" (d_9de02d3fb33d96da1855f4fbef549a0f), was not downloaded. |
| `nea-supermarket-licences.csv` | List of Supermarket Licences (d_11edd0117280c5776651d7891114c88c) | 478 | Supermarket locations after geocoding | This replaces the wrong id d_cac2c32f01960a3ad7202a99c27268a0. It is a list of licences, last updated 2024-06. It includes minimarts and butchers and has duplicate licences at one premises. There is no supermarket GeoJSON on data.gov.sg. |
| `households-dwelling-type-pa-census2020.json` | Resident Households by Planning Area of Residence and Type of Dwelling (d_388f9c61f437a588b47b008a012d13fa) | 32 | HDB flat-type mix and number of private households | Planning-area level only |
| `households-size-pa-census2020.json` | Resident Households by Planning Area of Residence and Household Size (d_0ef47f84a0776b27010b242038ea2c6b) | 32 | Household size marginal | Household size includes domestic workers (Census definition) |
| `households-structure-pa-census2020.json` | Resident Households by Planning Area of Residence and Household Structure (d_ce1804c655566f5089fff370bec37c2d) | 32 | Household structure marginal | |
| `households-tenancy-pa-census2020.json` | Resident Households by Planning Area of Residence and Tenancy (d_1ca435a3b62aafa6857d96368971765b) | 32 | Owner versus rented | |
| `population-dwelling-type-subzone-census2020.json` | Resident Population by Planning Area/Subzone of Residence and Type of Dwelling (d_7f243956483d5901f237e6f87b096636) | 388 | Persons in HDB, condominium and landed housing by subzone | Rounded to the nearest 10; "-" means nil |
| `population-age-floor-area-subzone-census2020.json` | Resident Population by Planning Area/Subzone, Age Group and Floor Area of Residence (d_9e035622439b5d25a63d7ea0699c9451) | 388 | Age by dwelling size, by subzone | Rounded to the nearest 10 |
| `labour-force-status-sex-pa-census2020.json` | Resident Population Aged 15+ by Planning Area of Residence, Labour Force Status and Sex (d_e9b1f437263fceebc0c1f0e60cd7b0f0) | 32 | Employed fraction by sex | |
| `employed-residence-transport-pa-census2020.json` | Employed Residents 15+ by Planning Area of Residence and Usual Mode of Transport to Work (d_1f8f5ec7201964e365c77551cab99503) | 32 | Commuting context | |
| `employed-residence-traveltime-pa-census2020.json` | Employed Residents 15+ by Planning Area of Residence and Travelling Time to Work (d_9ebad44ae5f9dff4ccc577a59ac4b208) | 32 | Proxy for working inside versus outside the planning area | |
| `employed-residence-industry-pa-census2020.json` | Employed Residents 15+ by Planning Area of Residence and Industry (d_a9b684696b39023c4b12f13e57aa2dfd) | 32 | Workplace type mix | |
| `employed-workplace-age-sex-pa-census2020.json` | Employed Residents 15+ by Planning Area of Workplace, Age Group and Sex (d_22063c84778e6535b92b4d8f93fd2525) | 48 | Size of the inbound working population | Counts residents only; non-resident workers are excluded |
| `employed-workplace-transport-pa-census2020.json` | Employed Residents 15+ by Planning Area of Workplace and Usual Mode of Transport to Work (d_f6ddbf6228d561454e27dd158846c688) | 48 | Inbound commuting | |
| `employed-workplace-traveltime-pa-census2020.json` | Employed Residents 15+ by Planning Area of Workplace and Travelling Time to Work (d_8ec1d0f5a86e5492f98e8598d6d258d1) | 47 | Inbound commuting | |
| `employed-workplace-transport-region-of-residence-census2020.json` | Employed Residents 15+ by Planning Area of Workplace, Usual Mode of Transport to Work and Planning Region of Residence (d_5b38192e9c6f8d2c5f38c70939c76e71) | 48 | Origin region of Queenstown workers | This is the only public origin and destination breakdown: workplace planning area by residence region. No planning area by planning area matrix exists on data.gov.sg or in the SingStat TableBuilder search. |
| `students-transport-pa-census2020.json` | Resident Students 5+ by Planning Area of Residence and Usual Mode of Transport to School (d_9eaccc6cc0f257cfd74d5c1ceb0fb663) | 32 | School travel context | |
| `students-traveltime-pa-census2020.json` | Resident Students 5+ by Planning Area of Residence and Travelling Time to School (d_6fce8e61bf5c5ce7ad36f770cb0faf78) | 32 | Proxy for schooling inside versus outside the planning area | |

These tables are already stored in `planning-evidence/` and were not duplicated here: `age-sex-2020.json` (population by subzone, age and sex) and `students-level-census2020.json` (students by planning area and level).

## Derived files

All are in EPSG:3414 (SVY21, metres). In the point CSVs, `x` and `y` are SVY21 coordinates. `subzone`, `subzone_code` and `planning_area` come from a point-in-polygon join with the MP2019 subzones. `in_queenstown` is TRUE inside the planning-area polygon, and `dist_to_qt_boundary_m` is 0 inside and the distance to the boundary outside.

| File | Rows / features | Made from | Use | Caveats |
|---|---|---|---|---|
| `hdb-blocks-geocoded-derived.csv` | 901 | Residential blocks in HDB towns QT, BT, CL and BM, geocoded with OneMap using block number plus road name | Candidate block locations | All 901 matched: 825 exact and 76 ambiguous (the point used is the first match) |
| `moe-schools-geocoded-derived.csv` | 58 | MOE schools whose `dgp_code` is one of the 13 planning areas that touch the 2 km buffer, geocoded by postal code | School locations | 25 exact and 33 ambiguous; none unmatched. Ambiguous here means one postal code covers several campus buildings, up to 311 m apart (Hwa Chong). |
| `supermarkets-geocoded-derived.csv` | 478 | All supermarket licences, geocoded by postal code | Supermarket locations | 266 exact, 189 ambiguous and 23 unmatched. None of the unmatched records are near Queenstown. |
| `queenstown-planning-area-derived.geojson` | 1 | MP2019 planning-area layer | Study area | |
| `queenstown-subzones-derived.geojson` | 15 | MP2019 subzone layer | Subzones; `SUBZONE_N` matches the Census subzone labels after case folding | Census spells "National University Of S'pore", while URA uses "NATIONAL UNIVERSITY OF S'PORE" |
| `queenstown-land-use-derived.geojson` | 1,965 | MP2019 land use intersected with Queenstown | Workplace and amenity zoning (`LU_DESC`, `GPR`, `area_m2`) | Zoning, not use. Slivers of 1 m² or less were dropped. |
| `queenstown-hdb-residential-blocks-derived.csv` | 242 | Geocoded HDB blocks inside Queenstown | Household locations and dwelling units by flat type | Current stock. 14 blocks (2,409 units) were completed after 2020. |
| `queenstown-schools-derived.csv` | 32 | Geocoded MOE schools within 2 km | School locations with `mainlevel_code` | |
| `queenstown-preschools-derived.csv` | 253 | ECDA preschools within 2 km | Preschool locations | No capacity data |
| `queenstown-hawker-centres-derived.csv` | 29 | NEA hawker centres within 2 km | Hawker centres | Filter on `in_queenstown` and `STATUS` |
| `queenstown-community-clubs-derived.csv` | 12 | Community clubs within 2 km | Community clubs | Ulu Pandan CC is marked "(U/C)" (under construction) in the source |
| `queenstown-supermarkets-derived.csv` | 60 | Geocoded supermarket licences within 2 km | Supermarkets | Includes small licensees, and several licences can share one premises |

## Summary facts

**Subzones and residents** (`age-sex-2020.json`, rounded to the nearest 10). Queenstown has 15 subzones and 95,930 residents. By subzone: Commonwealth 7,000; Dover 11,080; Ghim Moh 13,850; Holland Drive 12,680; Kent Ridge 80; Margaret Drive 16,090; Mei Chin 15,570; National University of Singapore 240; One North 720; Pasir Panjang 1 4,510; Pasir Panjang 2 3,060; Port 120; Queensway 270; Singapore Polytechnic 100; Tanglin Halt 10,590. By dwelling type, residents number 79,040 in HDB flats, 11,910 in condominiums and other apartments, and 3,540 in landed property.

**Residential HDB blocks** (current stock). There are 242 blocks with 34,920 dwelling units. All are in HDB town QT; none of the residential blocks in BT, CL or BM fall inside the planning area. By subzone: Mei Chin 54, Margaret Drive 52, Holland Drive 32, Commonwealth 32, Ghim Moh 26, Tanglin Halt 25, Dover 21. Sold units: 2-room 1,464; 3-room 13,557; 4-room 10,429; 5-room 4,340; executive 356; studio 367; 1-room 0; multigeneration 0. Rental units: 1-room 575; 2-room 2,188; 3-room 1,586; other 58. Blocks completed in 2020 or earlier: 228 blocks with 32,511 units.

**Census 2020 households.** Queenstown has 37,053 resident households. HDB households number 31,259: 1- to 2-room 3,814; 3-room 13,661; 4-room 9,424; 5-room and executive 4,360. There are 4,676 condominium and other apartment households, 1,032 landed, and 86 others. The implied number of occupied private dwellings is 5,708 (4,676 + 1,032). HDB units built by 2020 total 32,511, against 31,259 HDB households. The gap fits vacancy, non-resident occupants, and rental and studio units (assumption, not verified). Household size: 1 person 8,278; 2 persons 10,224; 3 persons 7,181; 4 persons 5,959; 5 persons 3,411; 6 persons 1,284; 7 persons 500; 8 or more 215. Tenancy: 31,270 owner-occupied and 5,269 rented.

**Work.** Queenstown has 48,300 employed residents aged 15 and over, out of 80,302 residents in that age group. 7,103 of the 45,868 employed residents with a reported travel time travel 15 minutes or less. 131,782 employed residents work in Queenstown, so the area is a net importer of workers.

**Schools, inside Queenstown.** There are 10 schools: 3 primary (Fairfield Methodist Primary, New Town Primary, Queenstown Primary); 5 secondary (Fairfield Methodist Secondary, New Town Secondary, Queenstown Secondary, Queensway Secondary, and School of Science and Technology); 1 junior college (Anglo-Chinese Junior College); and 1 mixed-level school (ACS Independent). Within 2 km there are 32 schools: 14 primary, 14 secondary, 3 mixed level and 1 junior college.

**Other venues.** Preschools: 81 inside Queenstown and 253 within 2 km. Hawker centres: 9 inside (8 existing and 1 under construction) and 29 within 2 km. Community clubs: 4 inside (Buona Vista, Dover, Queenstown, Ulu Pandan) and 12 within 2 km. Supermarket licences: 16 inside and 60 within 2 km.

**Geocoding** (OneMap search, no token). HDB: 901 of 901 matched (100%), 825 exact and 76 ambiguous. Of the 242 blocks kept for Queenstown, 225 are exact and 17 are ambiguous, and every ambiguous one has matches within 31 m of each other. The two worst ambiguous HDB matches, blocks 2 and 3 Queen's Rd at about 650 m spread, are BT-town blocks outside Queenstown under both candidate points. MOE schools: 58 of 58 matched, 25 exact and 33 ambiguous (multi-building campuses). Supermarkets: 455 of 478 matched (95%), and 23 are unmatched, all far from Queenstown. Unauthenticated OneMap search allows only about one request per second; faster rates get HTTP 429.

## Not obtained

- A resident origin and destination matrix from planning area of residence to planning area of workplace (or of school). Census 2020 publishes only workplace planning area by residence region.
- Preschool capacity and type, and school enrollment by school. Neither is in these datasets.
- A supermarket GeoJSON. The licence CSV, geocoded, is used instead.
