# Data inputs: read the stored public tables into tidy data frames.
#
# Every table was downloaded from data.gov.sg (or MOM/SingStat) and is stored
# unchanged in planning-evidence/ with a .source.json sidecar recording its URL,
# retrieval date and SHA-256 hash. These readers never download anything: they
# verify the stored file against its sidecar hash and fail loudly on mismatch,
# so the model can only run on the exact inputs documented in the report.

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(purrr)
  library(jsonlite)
  library(digest)
})

evidence_dir <- function() {
  d <- Sys.getenv("A4_EVIDENCE_DIR", unset = NA)
  if (is.na(d)) d <- file.path(a4_root(), "planning-evidence")
  if (!dir.exists(d)) stop("Evidence directory not found: ", d)
  d
}

# Root of the assessment folder. Set A4_ROOT on servers; locally it is found
# relative to this file's model/ directory.
a4_root <- function() {
  r <- Sys.getenv("A4_ROOT", unset = NA)
  if (!is.na(r)) return(normalizePath(r))
  normalizePath(file.path(getwd(), ".."), mustWork = TRUE)
}

# Read a stored data.gov.sg datastore_search JSON after checking its hash.
read_evidence_records <- function(file) {
  path <- file.path(evidence_dir(), file)
  side <- sub("\\.json$", ".source.json", path)
  if (!file.exists(path)) stop("Missing input table: ", path)
  if (!file.exists(side)) stop("Missing provenance sidecar: ", side)
  meta <- fromJSON(side)
  got <- digest(file = path, algo = "sha256")
  if (!identical(got, meta$sha256))
    stop("Checksum mismatch for ", file, ": expected ", meta$sha256, ", got ", got)
  recs <- fromJSON(path)$result$records
  if (is.null(recs) || nrow(recs) == 0) stop("No records in ", file)
  if (!is.null(meta$rows) && nrow(recs) != meta$rows)
    stop(file, " has ", nrow(recs), " records but its sidecar records ", meta$rows)
  as_tibble(recs)
}

# Census cells use "-" for nil (a structural zero) and may carry thousands
# separators. Anything else that fails to parse is an error, never a silent NA.
parse_count <- function(x) {
  x <- trimws(gsub(",", "", as.character(x)))
  x[x == "-"] <- "0"
  out <- suppressWarnings(as.numeric(x))
  bad <- is.na(out) & !(is.na(x) | x == "")
  if (any(bad)) stop("Unparseable count values: ", paste(unique(x[bad]), collapse = ", "))
  out
}

clean_label <- function(x) trimws(gsub(" ", " ", x))

size_levels <- c("1", "2", "3", "4", "5", "6", "7", "8+")
size_cols <- c("1Person", "2Persons", "3Persons", "4Persons", "5Persons",
               "6Persons", "7Persons", "8orMorePersons")

# D1. Resident population by 5-year age band and sex: the national total row,
# a planning-area total row (area = "Queenstown") or one subzone row.
read_age_sex <- function(area = NULL) {
  recs <- read_evidence_records("age-sex-2020.json")
  key <- if (is.null(area)) "Total" else area
  tot <- recs |> filter(Number == key)
  if (nrow(tot) != 1) stop("age-sex table: expected one row labeled '", key, "'")
  age_sex_long(tot)
}

# All subzone rows of a planning area (the rows between its total row and the
# next planning area's total row), in long form with a subzone column.
read_age_sex_subzones <- function(area) {
  recs <- read_evidence_records("age-sex-2020.json") |> mutate(row = row_number())
  start <- which(recs$Number == paste(area, "- Total"))
  if (length(start) != 1) stop("no planning-area total row for ", area)
  ends <- which(grepl(" - Total$", recs$Number) & recs$row > start)
  stop_row <- if (length(ends)) ends[1] - 1L else nrow(recs)
  sz <- recs[(start + 1L):stop_row, ]
  bind_rows(lapply(seq_len(nrow(sz)), function(i)
    age_sex_long(sz[i, ]) |> mutate(subzone = clean_label(sz$Number[i]))))
}

age_sex_long <- function(tot) {
  tot |>
    select(matches("^(Males|Females)_")) |>
    select(-ends_with("_Total")) |>
    pivot_longer(everything(), names_to = c("sex", "band"),
                 names_pattern = "^(Males|Females)_(.*)$", values_to = "count") |>
    mutate(count = parse_count(count),
           sex = recode(sex, Males = "M", Females = "F"),
           age_lo = as.integer(sub("^(\\d+).*$", "\\1", band)),
           age_hi = as.integer(ifelse(grepl("andOver", band), "120",
                                      sub("^\\d+_(\\d+)$", "\\1", band)))) |>
    select(sex, age_lo, age_hi, count) |>
    arrange(sex, age_lo)
}

# D2. Resident households by household structure and size (size includes
# domestic workers). Returns the eight leaf structures used for synthesis.
read_structure_size <- function() {
  recs <- read_evidence_records("household-structure-size-2020.json") |>
    mutate(Number = clean_label(Number), row = row_number())
  # Leaf rows, identified by position because labels repeat across parents.
  leaf <- tribble(
    ~row, ~structure,
    3L,  "one_person",
    4L,  "no_nucleus_multi",
    6L,  "nucleus1_gen1",
    7L,  "nucleus1_gen2",
    8L,  "nucleus1_gen3plus",
    10L, "nucleus2_gen12",
    11L, "nucleus2_gen3plus",
    12L, "nucleus3plus"
  )
  expect <- c("One Person", "Two or More Persons", "One Generation", "Two Generations",
              "Three or More Generations", "One or Two Generations",
              "Three or More Generations", "Three or More Family Nuclei")
  if (!identical(recs$Number[leaf$row], expect))
    stop("household structure table rows are not in the expected order")
  out <- recs |>
    inner_join(leaf, by = "row") |>
    select(structure, all_of(size_cols)) |>
    pivot_longer(-structure, names_to = "size_col", values_to = "households") |>
    mutate(households = parse_count(households),
           size = factor(size_levels[match(size_col, size_cols)], levels = size_levels)) |>
    select(structure, size, households)
  # The published cells do not sum exactly to the published total (1,372,562
  # against 1,372,559): a small inconsistency in the source table. Differences
  # within 0.001% are accepted and recorded; anything larger is an error.
  total <- parse_count(recs$Total[recs$Number == "Total"])
  gap <- sum(out$households) - total
  if (abs(gap) > 1e-5 * total)
    stop("structure-by-size leaves sum to ", sum(out$households), ", not the total ", total)
  attr(out, "published_total") <- total
  attr(out, "cell_sum_minus_total") <- gap
  out
}

# D3. Households by size and floor-area band, with published persons and
# median floor area per person (Census 2020). Excludes households without
# floor-area information.
read_size_floor_area <- function() {
  recs <- read_evidence_records("household-size-floor-area-census2020.json") |>
    mutate(Number = clean_label(Number))
  band_cols <- c(le60 = "FloorAreaofResidence_60sqm", `60_80` = "FloorAreaofResidence_60to80sqm",
                 `80_100` = "FloorAreaofResidence_80to100sqm",
                 `100_120` = "FloorAreaofResidence_100to120sqm", gt120 = "FloorAreaofResidence_120sqm")
  by_size <- recs |>
    filter(Number != "Total") |>
    mutate(size = factor(c("1", "2", "3", "4", "5", "6", "7", "8+")[match(
      Number, c("1 Person", "2 Persons", "3 Persons", "4 Persons", "5 Persons",
                "6 Persons", "7 Persons", "8 or More Persons"))], levels = size_levels))
  if (anyNA(by_size$size)) stop("unexpected size labels in floor-area table")
  bands <- by_size |>
    select(size, all_of(band_cols)) |>
    pivot_longer(-size, names_to = "band", values_to = "households") |>
    mutate(households = parse_count(households),
           band = factor(band, levels = names(band_cols)))
  summary <- by_size |>
    transmute(size, households = parse_count(Total),
              persons = parse_count(NumberofPersonsinHouseholds),
              mean_area_pp = parse_count(MeanFloorAreaperPerson_sqm),
              median_area_pp = parse_count(MedianFloorAreaperPerson_sqm))
  chk <- bands |> group_by(size) |> summarise(h = sum(households), .groups = "drop") |>
    inner_join(summary, by = "size")
  # Published band cells can differ from the published row totals by a few
  # households (source rounding). Accept gaps within 0.01% of a row; record them.
  if (any(abs(chk$h - chk$households) > 1e-4 * chk$households))
    stop("floor-area bands do not sum to size totals")
  summary$band_sum_minus_total <- chk$h[match(summary$size, chk$size)] - summary$households
  list(bands = bands, summary = summary,
       overall_median_area_pp = parse_count(recs$MedianFloorAreaperPerson_sqm[recs$Number == "Total"]))
}

# D4. Living arrangement of residents aged 65+ in resident households, by sex.
read_older_living_arrangement <- function() {
  recs <- read_evidence_records("age65-living-arrangement-census2020.json")
  tot <- recs |> filter(Number == "Total")
  if (nrow(tot) != 1) stop("older living-arrangement table: expected one Total row")
  map <- c(
    spouse_no_child        = "LivingwithSpouse_NoChildreninHousehold",
    spouse_child_employed  = "LivingwithSpouse_WithAtLeastOneEmployedChild",
    spouse_child_nonemp    = "LivingwithSpouse_WithAllNon_EmployedChildren",
    child_no_spouse_emp    = "LivingWithChildrenbutWithoutSpouse_WithAtLeastOneEmployedChild",
    child_no_spouse_nonemp = "LivingWithChildrenbutWithoutSpouse_WithAllNon_EmployedChildren",
    alone                  = "NotLivingWithSpouseorChildren_One_PersonHousehold",
    other_elderly_only     = "NotLivingWithSpouseorChildren_WithOtherElderlyPersonsOnly",
    other                  = "NotLivingWithSpouseorChildren_Others")
  out <- imap_dfr(map, function(col, key) {
    tibble(arrangement = key,
           M = parse_count(tot[[paste0(col, "_Males")]]),
           F = parse_count(tot[[paste0(col, "_Females")]]))
  }) |>
    pivot_longer(c(M, F), names_to = "sex", values_to = "persons")
  if (sum(out$persons) != parse_count(tot$Total_Total))
    stop("older living-arrangement categories do not sum to the total")
  out
}

# Married couples by age group of wife (rows) and husband (columns).
read_couple_ages <- function() {
  recs <- read_evidence_records("married-couples-age-census2020.json") |>
    mutate(Number = clean_label(Number)) |>
    filter(Number != "Total")
  cols <- grep("^Total_AgeGroupofHusband_Years_", names(recs), value = TRUE)
  recs |>
    select(wife = Number, all_of(cols)) |>
    pivot_longer(-wife, names_to = "husband", values_to = "couples") |>
    mutate(couples = parse_count(couples),
           husband = sub("^Total_AgeGroupofHusband_Years_", "", husband),
           wife_lo = band_lower(wife), husband_lo = band_lower(husband))
}

band_lower <- function(x) {
  x <- gsub(" ", "", x)
  out <- rep(NA_integer_, length(x))
  out[grepl("^Below30", x)] <- 20L
  out[grepl("^65", x)] <- 65L
  num <- is.na(out) & grepl("^\\d+", x)
  out[num] <- as.integer(sub("^(\\d+).*$", "\\1", x[num]))
  if (anyNA(out)) stop("Unrecognized age band labels: ", paste(x[is.na(out)], collapse = ", "))
  out
}

# Labour force participation (%), by sex and 5-year age band, for one year.
read_lfpr <- function(year = "2020") {
  recs <- read_evidence_records("labour-force-participation-age-sex.json") |>
    mutate(label = clean_label(DataSeries))
  if (!year %in% names(recs)) stop("year ", year, " not in labour force table")
  sex <- case_when(grepl("^Total Resident", recs$label) ~ "T",
                   grepl("^Male Resident", recs$label) ~ "M",
                   grepl("^Female Resident", recs$label) ~ "F")
  recs$sex <- sex
  recs <- fill(recs, sex)
  recs |>
    filter(grepl("Years", label), sex %in% c("M", "F")) |>
    transmute(sex, label, rate = parse_count(.data[[year]]) / 100) |>
    filter(!label %in% c("65 Years & Over", "15 - 24 Years", "25 - 64 Years")) |>
    mutate(age_lo = as.integer(sub("^(\\d+).*$", "\\1", label)),
           age_hi = as.integer(ifelse(grepl("& Over", label), "120",
                                      sub("^\\d+ - (\\d+) Years$", "\\1", label))))
}

# Resident students aged 5+ by level attending (national total).
read_students <- function() {
  recs <- read_evidence_records("students-level-census2020.json")
  tot <- recs |> filter(Number == "Total")
  tot |>
    select(-any_of(c("_id", "Number", "Total"))) |>
    pivot_longer(everything(), names_to = "level", values_to = "students") |>
    mutate(students = parse_count(students))
}

# Foreign domestic workers, December of each year, by subtraction of two MOM series.
read_fdw_stock <- function() {
  tot <- read_evidence_records("foreign-workforce-total.json") |>
    transmute(month, total = parse_count(count))
  ex <- read_evidence_records("foreign-workforce-excl-fdw.json") |>
    transmute(month, excl_fdw = parse_count(count))
  inner_join(tot, ex, by = "month") |> mutate(fdw = total - excl_fdw)
}

# Everything the population synthesis needs, in one validated list.
load_inputs <- function() {
  list(age_sex = read_age_sex(),
       structure_size = read_structure_size(),
       floor_area = read_size_floor_area(),
       older_living = read_older_living_arrangement(),
       couples = read_couple_ages(),
       lfpr = read_lfpr("2020"),
       students = read_students(),
       fdw_stock = read_fdw_stock())
}
