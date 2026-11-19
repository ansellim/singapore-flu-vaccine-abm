# Prioritizing additional influenza vaccine doses to older adults in Singapore households

A spatial agent-based model of seasonal influenza in a synthetic Singapore community and in the Queenstown planning area. It was written for SPH5105 Individual Assessment 4 (Agent-Based Models) at the National University of Singapore.

The full research report is [`report/SPH5105_Assessment_4_report.pdf`](report/SPH5105_Assessment_4_report.pdf) (Markdown source: [`report/report.md`](report/report.md)). This README summarizes the study. The report is the authoritative description of the methods and results.

## Question

When a fixed number of additional doses is added to existing vaccination, are fewer older adults (residents aged 65 and over) infected when the doses go to them first than when they are spread across all adults? The study also asks how the answer depends on:

- household composition, including live-in foreign domestic workers;
- transmission intensity, vaccine protection and exposure from outside the community;
- whether the answer holds when the model is scaled to a real planning area with its actual housing, schools and community venues.

## Methods in brief

- **Population.** Synthetic populations are built only from public aggregate statistics, mainly Census of Population 2020 tables. Whole households, including live-in domestic workers, are selected by simulated annealing to match household structure, age and sex, and older adults' living arrangements.
- **Contacts.** Individuals meet in households, preschools and schools, tertiary institutions, workplaces, community venues and domestic workers' rest-day gatherings, in half-day steps over 155 days. Contact intensities come from the Prem et al. contact matrices for Singapore.
- **Natural history and calibration.** Infectiousness follows a gamma density (mean 2.6 days) with a fixed incubation period. Half of symptomatic individuals stay home. The transmission scale and household intensity were calibrated to adult attack proportions in a Singapore serological cohort. This gives:
  - parameter sets R1 to R4 at the reference level;
  - L1 and L2 at a lower level;
  - O1 to O4, recalibrated with continued outside exposure;
  - an uncalibrated higher-transmission set, H1.
- **Arms.** Each population and epidemic seed is run under three arms with shared random numbers:
  - Arm A: existing vaccination only;
  - Arm B: 10 additional doses per 100 adults, spread across all adults;
  - Arm C: the same doses, given to adults aged 65 and over first.
- **Primary outcome.** The older-adult attack proportion under Arm C minus that under Arm B, in percentage points. Negative values favor prioritization.
- **Design.**
  - Original community: about 5,000 residents, 30 populations × 50 paired epidemics per scenario and parameter set, 112 combinations, 504,000 arm runs.
  - Full-scale extension: the whole Queenstown population (95,930 residents), placed both in a synthetic square of the same area and on Queenstown's real geography (URA Master Plan 2019 subzones, HDB blocks, private parcels, schools, preschools, hawker centers, community clubs and supermarkets). 16 populations × 10 epidemics per combination.

The model is described in full in Appendix B of the report and in [`model/ODD.md`](model/ODD.md) (Overview, Design concepts and Details protocol).

## Main findings

All results are conditional on the model and its parameter sets. Intervals describe simulation error only.

- **Reference assumptions.** In the original community, broad allocation was slightly ahead, by 0.04 to 0.17 points. Its advantage came from the few paired epidemics that became major outbreaks under prioritization but not under broad allocation.
- **What changed the direction.**
  - Continued exposure from outside the community favored prioritization (0.40 to 0.46 points at the prespecified level).
  - The vaccine's assumed protection of older adults relative to younger adults: weak older-adult protection favored broad allocation. In exploratory scenarios added post hoc, equal protection favored prioritization.
  - Without recalibration, both lower and higher proportions of symptomatic individuals staying home favored prioritization.
  - Achievable uptake in older adults changed the size of an advantage but not its direction.
- **Infections overall.** Broad allocation prevented more infections in the population as a whole under every assumption tested.
- **Full scale and real geography.**
  - At full scale, broad allocation was ahead by 0.26 to 0.34 points under the reference assumptions. The reference, outside-exposure and weak-protection results kept their directions.
  - Placing the same populations on Queenstown's real geography changed the comparison by −0.05 to +0.05 points.

## Repository layout

| Path | Contents |
|---|---|
| `model/R/` | Model code: population synthesis, settings and geography, transmission model, experiment runner, adapter for the course `abm_check()` harness |
| `model/scripts/` | Command-line scripts for building populations, calibration, pilot, experiments, analysis and figures |
| `model/scripts/data/` | Scripts that download, geocode and derive the Queenstown inputs |
| `model/tests/` | testthat verification suite |
| `model/ODD.md` | Model description (ODD protocol) |
| `planning-evidence/` | Public input tables, each with a `.source.json` sidecar recording the source URL, retrieval date and sha256; Queenstown inputs in `planning-evidence/queenstown/` (see its README) |
| `results/summary/` | Summary outputs (CSV, JSON, logs) behind every number in the report |
| `results/figures/` | Report figures; `ext_v1/` holds the superseded first extension run |
| `report/` | Report source, submitted PDF and the PDF build script (`report/build/`) |
| `docs/literature/` | Literature reviews on household structure and on vaccine effectiveness, and a review of spatial models for the Queenstown extension |
| `docs/reviews/` | Independent verification reviews of the full-scale extension against the code and summary outputs |

The raw simulation outputs are not in the repository. The steps below regenerate them.

## Reproducing the results

**Requirements.** R 4.4 or later with dplyr, tidyr, readr, purrr, tibble, jsonlite, digest, Matrix, ggplot2, patchwork, scales and testthat:

```r
install.packages(c("dplyr", "tidyr", "readr", "purrr", "tibble", "jsonlite", "digest",
                   "Matrix", "ggplot2", "patchwork", "scales", "testthat"))
```

The package sf is needed only for step 8. The data scripts in `model/scripts/data/` need only the Python 3 standard library.

**Environment variables (optional).**

| Variable | Default | Purpose |
|---|---|---|
| `A4_OUT` | `../outputs` | where raw outputs are written |
| `A4_CORES` | 4 | number of parallel processes |
| `A4_RLIB` | none | extra R library path |

The full experiment is designed for a multi-core server.

**Steps.** These are the steps of Appendix C of the report. Run them from `model/`:

1. `Rscript scripts/build_worlds.R 30`
2. `Rscript scripts/calibrate.R 5 10` and, for sets O1 to O4, `Rscript scripts/calibrate.R 5 10 open`
3. `Rscript scripts/pilot.R 10 10`
4. `Rscript scripts/run_experiment.R 30 50`
5. `Rscript scripts/analyze.R`
6. `Rscript scripts/figure_spatial.R 1 R3`
7. `Rscript scripts/run_abm_check.R <course setup.R> <world rds> 0.30 1.0`. This step needs the course's `abm_check()` harness, which is not included here.
8. `Rscript scripts/data/derive_queenstown.R`. Run it once, on a machine with the R package sf installed. It writes the Queenstown model inputs, which are already committed in `planning-evidence/queenstown/model/`.
9. `Rscript scripts/build_worlds_ext.R 16`
10. `Rscript scripts/run_extension.R 1 16 10`. The analyzed runs split the populations across three machines, using the same command with population ranges 1 to 10, 11 to 13 and 14 to 16.
11. `A4_MAP_POP=1 Rscript scripts/analyze_ext.R 16`

**Tests.** From `model/`, `Rscript tests/testthat.R` runs the verification suite. The log of the submitted run is `results/summary/test_log.txt`.

**Report PDF.** `python3 report/build/build_pdf.py` rebuilds the PDF from `report/report.md`. It needs pandoc and XeLaTeX.

## AI assistance

This work was generated with AI assistance under the supervision of Ansel. AI tools:

- carried out the literature searches and summarized the cited studies;
- retrieved and checked the public data sources;
- developed the detailed study design;
- wrote and tested the R code;
- ran the simulations on a university server;
- analyzed the results and drafted the report.

Ansel set the research direction, made the principal design decisions (the setting, disease, outcome, comparison and the inclusion of domestic workers), supervised the work and takes full responsibility for the submitted methods, results, interpretations and code. The verification reviews in `docs/reviews/` record independent checks of the results against the code and outputs.

## Data and license

The input data are public Singapore government datasets, mainly from data.gov.sg and SingStat, used under the [Singapore Open Data Licence](https://data.gov.sg/open-data-licence). The OneMap geocoding results also come from a public API. Each file's sidecar records its source. The Prem et al. contact matrices are from the published supplementary data (see `planning-evidence/prem2021/`).

The code is released under the MIT License (see `LICENSE`).
