# Geography in spatial ABMs of respiratory infection: literature check

Compiled 2026-11-19. All PMIDs/DOIs were checked against PubMed E-utilities or Crossref. "Full text" means I read the methods text (PMC); "abstract" means only the abstract or metadata was read, and any further detail is from prior knowledge and should be confirmed before citing.

## 1. Singapore models

**GeoDEMOS-R (NUS SSHSPH; Koo 2020, Dickens 2020).** Koo et al. ran FluTE on a synthetic Singapore population built with GeoDEMOS-R from the 2010 census, with individuals "allocated to workplaces or educational facilities on the basis of local transportation data and home addresses" (Koo, PMID 32213332, full text). Dickens et al. give more detail: households were built from 178 census tables (sample of 200,000 households), geolocated within **subzones**, and workers/students assigned to workplaces and schools using **commuting-time distributions from the Household Interview Travel Survey (HITS) and EZ-Link** fare-card data. Mixing occurs in household, school, workplace and a subzone-level community (PMID 34173590, full text). Scale is the **full resident population** (Koo's 279,000 infections = 7.4%, implying about 3.8 million agents); non-residents, including dormitory workers, are excluded, which Dickens flags as a limitation. I found no standalone peer-reviewed GeoDEMOS methods paper; details are in these papers and their appendices (appendices not read).

**A\*STAR IHPC influenza IBM (Zhang 2011, 2012).** Individual-based contact network from Singapore census 2000 and real-life contact data. It uses a **10% sample** (about 100,000 households) and generates 35 schools and about 5,300 workplaces from size distributions. Students go to "nearby" schools, but there is no explicit real geography (no subzones or coordinates), and public transport is a single giant mixing layer (PMID 22403634, full text; PMID 21326332, abstract).

**Chung and Chew 2021 multiplex SEIR ABM (COVID-19).** Non-spatial multiplex network (household, dormitory, workplace, temporal crowd, gathering layers). It uses a **reduced effective population** (about 1.89 million in households plus a capped 110,000 dormitory residents) instead of 5.6 million. Workplace sizes are gamma-distributed, and schools are treated like workplaces (PMID 33980920, full text).

**Massaro, Kondor and Ratti 2019 (dengue, SMART).** This model is not respiratory, but it is the clearest Singapore test of real versus stylized geography. Agents live on a regular grid (2,598 occupied cells), with home and work cells from **mobile phone CDRs (2.3 million agents)**, compared against random, truncated Levy and radiation (census-based) mobility. Flows are summarized at the 55 planning areas. Random mobility fit observed cases worst (R² 0.51 vs 0.65) (PMID 31729435, full text).

**Synthetic population work (transport, SMART/SimMobility).** Zhu and Ferreira used two-stage IPF with **building-level** information to place Singapore households (DOI 10.3141/2429-18, not in PubMed; abstract). Le et al. built a synthetic population of establishments (workplaces) for SimMobility (DOI 10.1016/j.trpro.2016.12.070; metadata only). I could not find a peer-reviewed Singapore-ETH/Future Cities Lab synthetic population paper used for epidemic modeling (not verified, so treat as absent rather than nonexistent).

## 2. Landmark non-Singapore spatial ABMs

- **Eubank 2004, EpiSims/TRANSIMS, Portland (~1.6 M).** Activity-based: census, land-use and mobility data place people at actual locations (PMID 15141212; abstract).
- **Ferguson 2005, Thailand (~85 M) and Ferguson 2006, GB/US (full populations).** The 2006 main text states the model is parameterized with "high-resolution population density data" (LandScan) and travel data. Households are placed on the density grid, schools are placed from school data, and workplaces are assigned via distance kernels fitted to travel-to-work data (details in the Supplement, not read) (PMIDs 16079797 abstract; 16642006 full main text).
- **Longini 2005, rural Thailand.** About 500,000 synthetic people in household/school/workplace/village mixing groups from Thai census demographics. The geography is **stylized**: localities without real coordinates (PMID 16079251; abstract, structure from prior knowledge).
- **Germann 2006, EpiCast, US (281 M).** Census-tract communities with CTPP tract-to-tract commuting (PMID 16585506; abstract).
- **Chao 2010, FluTE.** Census tracts subdivided into communities of 500 to 3,000; employment by tract (Census SF3); workers sent to destination tracts using CTPP commuting flows (commutes over 100 miles dropped); workgroups of about 20. Supports full US (280 M, 64,735 tracts) or regional subsets (PMID 20126529; full text). This is the engine Koo et al. adapted.
- **Halloran 2008, three-model comparison (Chicago, 8.6 M).** Ferguson, Longini/Chao and Eubank models with different spatial structures (PMID 18332436; abstract).
- **Ciofi degli Atti 2008 / Ajelli 2010 / Merler 2010, Italy and Europe.** Italy has 57 M people; households are placed by municipality; schools and workplaces are located at municipality centroids, or distributed proportional to population density. Commuting is assigned with a census-fitted gravity model, and community contacts use a distance kernel (PMIDs 18335060 and 20587041, full text). Merler 2010 extends this to Europe with air/rail data (PMID 19864279; abstract).
- **Synthetic population methods.** Beckman, Baggerly and McKay 1996, IPF on census microdata plus marginals (DOI 10.1016/0965-8564(96)00004-3; Crossref metadata only). Covasim/SynthPops (Kerr 2021): household/school/work networks from census data, with **no explicit spatial movement** ("not currently modeled explicitly"), and dynamic rescaling of agents (PMID 34310589; full text).

## 3. When is stylized geography acceptable?

I found **no explicit, peer-reviewed rule** stating when abstract geography suffices. The available evidence is indirect:

- Model-structure good practice says structure should be driven by the decision question (Pitman 2012 ISPOR-SMDM, PMID 22990086; metadata only, verify content).
- Halloran 2008 found qualitatively consistent intervention rankings across models with very different geographic detail. Ajelli 2010 found an ABM and a metapopulation model agree on large-scale timing. Both imply that **setting-based mixing structure (household/school/work) matters more than coordinates** for national NPI comparisons.
- Willem 2017 systematic review (PMID 28893198; full text) catalogs spatial features but offers no threshold guidance.
- Real geography matters when the question is spatial: targeted or ring prophylaxis (Ferguson 2005), spatial heterogeneity or hotspots (Koo figure 3; Chung's dormitories), or where random mobility misfits (Massaro 2019).

**Implication for your report:** two Singapore respiratory ABMs used no real geography (Zhang, Chung), and the GeoDEMOS-R line uses subzones plus HITS/EZ-Link. A stylized-geography influenza ABM is defensible if the question is non-spatial (school closure, vaccination timing). It should state that limitation, and ideally run a sensitivity check (random vs gravity/radiation commuting, à la Massaro).

## 4. Public Singapore data sources

| Source | URL | Status |
|---|---|---|
| URA Master Plan 2019 Subzone Boundary (No Sea) | https://data.gov.sg/datasets/d_8594ae9ff96d0c708bc2af633048edfb/view | Verified via API |
| HDB Property Information (block addresses, dwelling counts) | https://data.gov.sg/datasets/d_17f5382f26140b1fdae0ba2ef6239d2f/view | Verified via API |
| MOE General information of schools | https://data.gov.sg/datasets/d_688b934f82c1059ed0a6993d2a829089/view | Verified via API |
| SingStat Census 2020 / Table Builder (subzone population by age) | https://tablebuilder.singstat.gov.sg/ ; https://www.singstat.gov.sg/ | Landing pages only; specific release URL not verified |
| OneMap geocoding API | https://www.onemap.gov.sg/apidocs/ | Verified (HTTP 200) |
| LTA DataMall (passenger volume by origin-destination) | https://datamall.lta.gov.sg/content/datamall/en.html | Verified (HTTP 200) |
| URA Master Plan | https://www.ura.gov.sg/Corporate/Planning/Master-Plan | Verified (HTTP 200) |
| HITS | Not public (LTA survey); used by GeoDEMOS-R under access | No public URL found |
| EZ-Link records, mobile phone CDRs | Proprietary | Used by Dickens 2020 and Massaro 2019 |

Of the published Singapore models, **none** cites data.gov.sg/OneMap explicitly. GeoDEMOS-R used census tables plus restricted HITS/EZ-Link data; Massaro used census and CDRs.
