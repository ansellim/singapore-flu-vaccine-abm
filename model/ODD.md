# Model description (Overview, Design concepts and Details protocol)

This description follows the Overview, Design concepts and Details (ODD) protocol for describing individual-based and agent-based models, in its second update (Grimm et al. 2020, doi:10.18564/jasss.4259). It describes what the code in `model/R/` does. Section 8 maps every element to the code.

## 1. Purpose and patterns

The model compares two ways of allocating the same number of additional influenza vaccine doses in a Singapore population: to adults aged 65 and over first, or across all adults aged 18 and over. Both are added to existing age-specific vaccination. The primary output is the infection attack proportion among residents aged 65 and over during one 120-day wave. The model also shows how that comparison varies with older adults' household composition, including live-in foreign domestic workers, with transmission intensity, vaccine protection, exposure from outside the population and spatial structure.

The model is run on three geographies, which share every rule except where homes and destinations are placed:

- **Original community.** About 5,000 residents built from national Census 2020 tables, in a synthetic 4 km by 4 km square with four equal neighborhoods.
- **Part 1, synthetic square.** The resident population of the Queenstown planning area (95,930 residents in Census 2020), synthesized to Queenstown's age, sex and household-size distributions, in a synthetic square of Queenstown's land area (21.7 km²) with one neighborhood per populated Queenstown subzone (13).
- **Part 2, Queenstown.** The same synthetic populations placed on the real geography of the Queenstown planning area: Urban Redevelopment Authority Master Plan 2019 subzones, Housing and Development Board (HDB) residential blocks, private residential parcels, real school, preschool and tertiary sites, hawker centers, community clubs and supermarkets.

The model is judged fit for this purpose if it reproduces the following patterns.

- **Population.** The Census 2020 distributions of resident age and sex, household structure by size, and older adults' living arrangement by age; in Parts 1 and 2 also Queenstown's household-size distribution, and in Part 2 Queenstown's residents by subzone and age, residents by subzone and dwelling type, and households by dwelling type. Acceptance: standardized absolute error below 0.10 in every fitted table.
- **Adult infection.** The infection attack proportion among unvaccinated adults aged 21 to 75 in Singapore's 2009 pandemic waves. Acceptance: 11.5% to 15.5% at the reference level and 5.0% to 8.0% at the lower level.
- **Generation interval.** Acceptance: 2.1 to 3.0 days.
- **Household serial interval.** Acceptance: 2.9 to 4.3 days.

The model does not reproduce the serial interval pattern. Because the incubation period is fixed, the mean serial interval equals the mean generation interval, about 2.8 to 2.9 days.

## 2. Entities, state variables and scales

**Individuals** are residents and live-in foreign domestic workers. Each has:

- unique identifier, household identifier, sex and age;
- resident flag and domestic-worker flag;
- role links to spouse and parent;
- living arrangement if aged 65 or over, and severe difficulty in a basic activity (used only to place domestic workers);
- fixed home coordinates and neighborhood (subzone in Part 2);
- education level, school site and class, if a student;
- workplace, if employed;
- community venue site and venue group;
- rest-day gathering group, if a domestic worker;
- age band of the contact matrices (5-year bands, 0 to 4 through 75 and over);
- disease state, infection step and symptomatic flag;
- baseline vaccination;
- additional dose day.

**Households** have size class and family structure; occupants, residents and domestic-worker flag; floor area and floor area per occupant; neighborhood and coordinates; and in Part 2 a dwelling type (HDB 1 and 2 room, 3 room, 4 room, 5 room and executive, condominium or other apartment, landed property) and, for HDB households, the block.

**Settings** are classes at school sites, workplaces, community-venue groups at venue sites and the domestic workers' rest-day gathering groups. Group sizes are the same in all three geographies: classes of up to 15 (preschool), 30 (primary and secondary) or 50 (tertiary) students, a mean of 10 workers per workplace, venue groups of about 125 regular users and gathering groups of about 250 domestic workers. A real venue such as a hawker center therefore hosts several venue groups.

**Space** is two-dimensional in meters: a bounded square in the original community and Part 1, and Singapore's SVY21 projected coordinates (EPSG:3414) in Part 2. Individuals do not move between coordinates; distance determines which workplace, venue site and secondary or tertiary site an individual joins, and the nearest preschool and primary site.

**Time** advances in half-day steps: an even step is daytime and an odd step is nighttime. A run lasts 155 days (310 steps), and day 0 is a Monday. Half-day steps separate daytime settings (school, work and community) from the household at night, as in other influenza individual-based models (Chao et al., 2010), and are short relative to the 2.6-day mean generation interval.

**Disease states** are S (susceptible), I (infected and not yet recovered, including the latent period) and R (recovered or immune). Infectiousness is a function of infection age within I and is recorded separately.

## 3. Process overview and scheduling

Each step runs the same sequence (`simulate_arm`, `R/model.R`):

1. Vaccine protection that begins today is applied.
2. Disease states are frozen. Infectiousness is computed from each infected individual's infection age, with a lower weight if the infection is asymptomatic.
3. Individuals are placed for the step.
   - **Night:** everyone is at home.
   - **Weekday daytime:** students are at their class and employed adults at their workplace. Everyone not staying home, and not at a domestic workers' gathering, also visits their venue group. Individuals not at school, work or a gathering are at home.
   - **Weekends:** there is no school or work.
   - **Sunday daytime:** domestic workers who take their rest day attend their gathering group.
   - **Staying home:** symptomatic individuals who stay home do so from symptom onset to recovery.
4. Each susceptible individual's hazard from each setting is computed from the frozen infectious individuals present in that setting, and the external hazard is added.
5. One infection draw per susceptible individual, made with a pre-drawn uniform random number.
6. All transitions are committed at once: I to R at the end of the infectious period, and S to I for new infections. The setting of each new infection is attributed in proportion to the setting hazards. Its infector is drawn among infectious individuals in that setting, in proportion to their contributions.
7. Counts are recorded, and S + I + R = N is checked.

An individual infected in a step cannot transmit until a later step.

## 4. Design concepts

- **Basic principles.** The model is a stochastic individual-based transmission model in which contacts occur within shared, persistent settings. Vaccination reduces susceptibility to infection.
- **Emergence.** Attack proportions by age, household type and subzone, epidemic timing, the generation interval, the share of infections by setting and spatial spread arise from individual infections in settings and are not imposed.
- **Adaptation, objectives, learning and prediction.** None.
- **Sensing.** None. Staying home depends only on an individual's own symptoms.
- **Interaction.**
  - **Household:** per-pair intensity h divided by (household size minus 1) to the power 0.5.
  - **School and workplace:** frequency-dependent among those present, at the Prem et al. contact rates per attendee.
  - **Community:** age-structured using the Prem et al. "other locations" matrix for Singapore, made reciprocal for the synthetic population and spread across the members of each age band in the same venue group.
  - **Domestic workers' gathering:** frequency-dependent among the domestic workers present in the same gathering group.
- **Stochasticity.** Population synthesis, placement, setting assignment, prior immunity, baseline vaccination, the dose-queue order, symptoms, staying home, infection, setting attribution, infector choice and domestic workers' rest days are random. For each epidemic, all of these except population synthesis, placement and setting assignment are drawn once and shared by Arms A, B and C.
- **Collectives.** Households, classes, workplaces, venue groups, gathering groups and neighborhoods.
- **Observation.** Per step: S, I and R counts, infectious prevalence and new infections. Per individual: infection step, setting and infector. Per arm: summary outcomes, attack proportions for older adults by household stratum and attack proportions by neighborhood.

## 5. Initialization

### Population synthesis

`synthesize_population` (`R/population.R`) is a sample-free synthetic reconstruction followed by simulated annealing over whole households.

1. **Candidate households** are generated for every structure-by-size cell of the national Census 2020 table, from role templates. Couple ages come from the Census joint distribution of husband's and wife's age groups; children follow mother-to-child gaps of 20 to 42 years; grandparents follow generation gaps of 20 to 40 years.
2. **Domestic workers.** Each candidate exists with and without a domestic worker, who occupies one place within the published household size, because the Census counts live-in domestic workers as household members. The prior probability of a domestic worker is the observed 2020 share by age group for an older adult with no co-resident family, 0.49 if an older resident has severe difficulty, 0.25 if a child under 6 is present and 0.12 otherwise.
3. **Selection.** Simulated annealing (400,000 proposed swaps) selects whole households to fit household structure by size, resident age and sex, older adults' living arrangement by age, and the observed 15.8% of households with a domestic worker. In the original community the targets are national and the population has about 1,630 households and 5,000 residents. In Parts 1 and 2 the targets are Queenstown's: 95,930 residents with Queenstown's age and sex distribution, and 37,052 households with Queenstown's household-size distribution (the sum of the Census 2020 household-size cells), within which household structure follows the national distribution for each size. A population is accepted only if every fitted table has a standardized absolute error below 0.10.
4. **Floor area** in the original community and Part 1 is drawn from the national Census 2020 floor-area band distribution for the household's size, uniformly within the band. This assumes that floor area depends on household size only, not on income or location. In Part 2, floor area follows the dwelling type at the household's address (placement, below).

### Placement and settings

**Original community** (`assign_settings`, `R/settings.R`): households are placed uniformly in a random quadrant of a 4 km square. Each quadrant has one preschool and primary site; two secondary sites serve the west and east halves; one tertiary site serves everyone. Each worker chooses one of about 270 workplaces (one per 10 workers, placed uniformly) with weights exp(-distance / 1 km), and everyone chooses one of 40 venues with the same kernel.

**Part 1, synthetic square** (`square_layout`, `assign_settings_layout`, `R/geography.R`): a square of 21.7 km² (4.66 km side) with 13 neighborhoods, formed as the Voronoi cells of 13 random centers so that neighborhoods differ in size as subzones do. Households, school sites, venue sites and workplaces are placed uniformly at random, with the same numbers of preschool, primary, secondary, tertiary and venue sites as in Part 2.

**Part 2, Queenstown** (`queenstown_layout`, `R/queenstown.R`):

1. **Subzone and dwelling type.** A second annealing step assigns each household to a subzone and a dwelling type so that the population matches, at once, Queenstown's residents by subzone and 5-year age band, residents by subzone and dwelling type, and households by dwelling type (Census 2020).
2. **Address.** An HDB household is placed at an HDB residential block in its subzone, chosen in proportion to the block's number of flats of the household's type (HDB Property Information, geocoded with OneMap), with a random offset of up to 15 m in each coordinate. A household in a condominium, other apartment or landed property is placed at a random point on a private residential parcel of its kind in its subzone: Master Plan 2019 residential parcels with no HDB block within 20 m, sampled in proportion to parcel area times gross plot ratio, with parcels zoned for landed housing taken as landed.
3. **Floor area** is drawn uniformly within the range for the dwelling type: HDB 1 and 2 room 30 to 47 m², 3 room 60 to 75 m², 4 room 85 to 105 m², 5 room and executive 105 to 150 m², condominium 60 to 150 m² and landed 150 to 400 m² (the private ranges are assumed).
4. **Destinations.** School sites are the Ministry of Education primary and secondary schools and junior colleges within 1 km of Queenstown and the preschools within 500 m, geocoded by postal code; the tertiary sites are Anglo-Chinese Junior College, the National University of Singapore (Kent Ridge) campus and the Singapore Polytechnic campus. Workplaces are placed at points on parcels zoned for business, commerce (including mixed residential-commercial and white sites), institutions, places of worship, health care, education, sports and recreation, utilities, transport, special use and the port, in proportion to parcel area times plot ratio. Venue sites are the existing hawker centers and the community clubs within 300 m of Queenstown and the licensed supermarkets inside it.

**Shared rules in Parts 1 and 2:**

- **Education:** ages 3 to 6 attend preschool with probability 0.704; ages 7 to 16 attend school; ages 17 to 24 attend tertiary education with probability 0.652. Preschool and primary pupils attend their nearest site of that level, because primary school admission in Singapore gives priority by home distance. Secondary and tertiary students choose a site with weights exp(-distance / 1 km). Classes are formed by site, level and single year of age.
- **Work:** residents aged 15 and over who are not students work with their 2020 labor force participation rate by sex and age, at one of the workplaces (one per 10 workers) chosen with weights exp(-distance / 1 km).
- **Community:** everyone chooses a venue site with the same kernel and is assigned at random to one of its venue groups.
- **Gatherings:** domestic workers are divided at random into gathering groups of about 250.

All workplaces, schools and venues are inside or next to the modeled area. Contacts with people who live elsewhere, including at workplaces outside the area, are represented by the external hazard.

### Per epidemic

`draw_streams` and `simulate_arm`, `R/model.R`:

- 20% of individuals start in R (prior immunity).
- Baseline vaccination follows age-specific coverage from the National Population Health Survey 2024 for adult bands, 52.6% for ages 75 and over, 8% under 18 and 0% for domestic workers.
- No individual is infected at day 0.

## 6. Input data

| Input | Source | Use |
| --- | --- | --- |
| Resident age and sex, national, planning area and subzone | Census 2020, data.gov.sg d_d95ae740c0f8961a0b10435836660ce0 | Fitted |
| Household structure by size | Census 2020, d_5878c7d334eb84983a765d91bd270d7c | Fitted |
| Household size by floor area | Census 2020, d_46ff0d0429b30ac8d76d6778df32eb84 | Floor area given size |
| Older adults' living arrangement by age | SingStat M810821, 2020 | Fitted |
| Older adults' living arrangement by difficulty | Census 2020, d_df70e7fa7d362c880d9647440f67babf | Severe-difficulty rates |
| Married couples by age | Census 2020, d_cadd4d2df56ac4187847648f44ffcb9c | Spouse ages |
| Labor force participation | Ministry of Manpower, d_465c5bd4a9adae523f9577371daf5e24, 2020 | Employment |
| Students by level | Census 2020, d_b19c5bc4f6916b5481f6531918440fe6 | Enrollment rates |
| Households with a domestic worker | SingStat C030030, 2020 | 15.8% target |
| Older adults living only with a domestic worker | SingStat C010023 and M810821 | Domestic worker allocation |
| Vaccination coverage | National Population Health Survey 2024, Table 8.1 | Baseline vaccination |
| Contact matrices | Prem et al. 2021, corrected 2024 | Age mixing and contact rates |
| Households by size, planning area | Census 2020, d_0ef47f84a0776b27010b242038ea2c6b | Part 1 and 2 targets |
| Households by dwelling type, planning area | Census 2020, d_388f9c61f437a588b47b008a012d13fa | Part 2 targets |
| Residents by dwelling type, subzone | Census 2020, d_7f243956483d5901f237e6f87b096636 | Part 2 targets |
| Subzone and planning-area boundaries | URA Master Plan 2019 (no sea), d_8594ae9ff96d0c708bc2af633048edfb and d_4765db0e87b9c86336792efe8a1f7a66 | Part 2 geography |
| Land use | URA Master Plan 2019 land use, d_90d86daa5bfaa371668b84fa5f01424f | Private dwellings and workplaces |
| HDB blocks and flats by type | HDB Property Information, d_17f5382f26140b1fdae0ba2ef6239d2f, geocoded with OneMap | Part 2 addresses |
| Schools | Ministry of Education, d_688b934f82c1059ed0a6993d2a829089, geocoded with OneMap | Part 2 school sites |
| Preschools | Early Childhood Development Agency, d_61eefab99958fd70e6aab17320a71f1c | Part 2 preschool sites |
| Hawker centers, community clubs, supermarkets | National Environment Agency d_4a086da0a5553be1d89383cd90d07ecd; People's Association d_f706de1427279e61fe41e89e24d440fa; National Environment Agency supermarket licenses d_11edd0117280c5776651d7891114c88c, geocoded with OneMap | Part 2 venue sites |

Every file is stored in `planning-evidence/` with its source URL, retrieval date and SHA-256 hash. The tabular readers verify the hash before use. The Queenstown spatial inputs are converted once into model-ready tables by `scripts/data/derive_queenstown.R`, which records the hashes of its inputs and outputs. No input changes during a run.

## 7. Submodels

**Natural history.**

- Infectiousness over infection age follows a gamma density with mean 2.6 days and standard deviation 1.1 days, is zero for the first day (the latent period), is truncated at 8 days, when the individual recovers, and is normalized to a total of one unit.
- 67% of infections become symptomatic, at infection age 1.5 days. Never-symptomatic infections are 0.57 times as infectious.
- Half of symptomatic individuals stay home from onset until recovery.

**Transmission.**

- For susceptible individual i, the probability of infection in a step of length 0.5 days is P = 1 - exp(-0.5 × s_i × (sum over settings k of λ_ik + λ_ext)), where s_i is residual susceptibility after vaccination and λ_ik is the hazard from infectious individuals present with i in setting k.
- School, workplace, community and gathering hazards represent a day's contacts and are applied at twice their daily rate during the daytime step.
- The transmission scale τ and household intensity h are calibrated in the original community. Sets R1 to R4 (reference level), L1 and L2 (lower level), H1 (higher transmission, not calibrated) and O1 to O4 (calibrated with continued external exposure of 0.0001 per day and used only with that exposure) are reported separately. Parts 1 and 2 use sets R1 to R4 and O1 to O4 without recalibration; their adult attack proportions under existing vaccination are reported as a check.

**External exposure.** The external hazard represents infection acquired from people outside the modeled population, including importations. In the reference scenario it is 0.001 per susceptible-day on days 35 to 39 and zero otherwise, so the wave is seeded by importations and then sustained by local transmission. In the open-boundary scenarios it continues at 0.0001 per day after day 39 (and at 0.00002, 0.00005 or 0.0002 in added scenarios of the original community).

**Vaccination.**

- Protection is a proportional reduction in susceptibility of 40% (ages 18 to 64), 30% (65 and over) or 50% (under 18). Baseline protection is multiplied by 0.91 for waning.
- **Budget:** 10 additional doses per 100 resident adults, rounded down, given in equal daily numbers on days 7 to 20 to eligible residents aged 18 and over without a baseline dose. Each dose protects from 14 days after it is given.
- **Order:** Arm B follows one shared random ordering of all eligible adults. Arm C takes every eligible resident aged 65 and over first, in that same order, and gives any remaining doses to younger adults in the same order. Doses given to individuals already infected or immune count against the budget.
- **Uptake cap:** in the uptake-cap scenarios, residents aged 65 and over are removed from the queue in every arm once baseline and campaign doses together would cover more than 75% of them; their places pass to younger adults, so both arms still give the same number of doses.

**Living space** (original community only). With γ greater than 0, a household's pair intensity is multiplied by (median area per occupant / household area per occupant)^γ, bounded to 0.5 to 2 and normalized to a mean of 1 weighted by occupant pairs.

**Shuffled destinations.** Workplace memberships are permuted among workers, venue memberships among all individuals and class memberships among students of the same level and age. This preserves every group's size, and the age composition of classes, while breaking the link between home location and destination.

## 8. Code map

| Element | File and function |
| --- | --- |
| Input data and checksum verification | `R/data_inputs.R`: `read_evidence_records`, `read_age_sex`, `load_inputs` |
| Population synthesis | `R/population.R`: `generate_pool`, `anneal_select`, `fit_report`, `synthesize_population` |
| Original community geography and settings | `R/settings.R`: `assign_settings`, `shuffle_destinations`, `contact_rates` |
| Parts 1 and 2 settings, Part 1 layout | `R/geography.R`: `assign_settings_layout`, `square_layout` |
| Part 2 layout | `R/queenstown.R`: `queenstown_inputs`, `assign_cells`, `queenstown_layout`; `scripts/data/derive_queenstown.R` |
| Scheduling and transmission | `R/model.R`: `simulate_arm`, `infectiousness_profile`, `dose_queue`, `draw_infectors` |
| Random numbers shared across arms | `R/model.R`: `draw_streams` |
| Outcomes | `R/experiment.R`: `arm_outcomes`, `stratum_outcomes`, `neighborhood_outcomes`, `run_task` |
| Course harness adapter | `R/abm_check_adapter.R` |
| Scenarios and parameter sets | `scripts/scenarios.R` |
| Simulation experiments | `scripts/calibrate.R`, `scripts/run_experiment.R`, `scripts/build_worlds_ext.R`, `scripts/run_extension.R`, `scripts/analyze.R`, `scripts/analyze_ext.R` |
| Verification tests | `tests/testthat/` |
