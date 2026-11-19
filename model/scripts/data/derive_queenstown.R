# Derive the model-ready Queenstown inputs (Part 2) from the stored public files
# in planning-evidence/queenstown/. Needs sf; run locally from model/:
#   Rscript scripts/data/derive_queenstown.R
# Writes CSVs to planning-evidence/queenstown/model/ with a manifest of input
# and output SHA-256 hashes. Random point sampling uses a fixed seed.

suppressPackageStartupMessages({
  library(sf)
  library(dplyr)
  library(tidyr)
  library(readr)
  library(jsonlite)
  library(digest)
})
sf_use_s2(FALSE)
set.seed(20201)

ev <- normalizePath("../planning-evidence")
qd <- file.path(ev, "queenstown")
out <- file.path(qd, "model")
dir.create(out, showWarnings = FALSE)
used <- character(0)
inp <- function(f) { p <- file.path(qd, f); if (!file.exists(p)) stop("missing ", p); used <<- c(used, p); p }
records <- function(f) fromJSON(inp(f))$result$records
num <- function(x) { x <- gsub(",", "", as.character(x)); x[x %in% c("-", "na", "")] <- "0"; as.numeric(x) }
html_field <- function(x, field) {
  m <- regmatches(x, regexpr(sprintf("<th>%s</th>\\s*<td>[^<]*</td>", field), x))
  out <- rep(NA_character_, length(x)); has <- grepl(sprintf("<th>%s</th>", field), x)
  out[has] <- trimws(sub(sprintf(".*<th>%s</th>\\s*<td>([^<]*)</td>.*", field), "\\1", m))
  out
}
title <- function(x) tools::toTitleCase(tolower(x))

# Boundaries (EPSG:3414).
pa <- st_read(inp("queenstown-planning-area-derived.geojson"), quiet = TRUE) |> st_transform(3414)
sz <- st_read(inp("queenstown-subzones-derived.geojson"), quiet = TRUE) |> st_transform(3414) |>
  mutate(subzone = title(SUBZONE_N)) |> select(subzone)
# D1 labels use "S'pore"; title case gives "S'pore" as well.
sz$area_m2 <- as.numeric(st_area(sz))
qt_union <- st_union(pa)

# Census 2020: residents by subzone and age band (D1, already stored).
d1 <- fromJSON(file.path(ev, "age-sex-2020.json"))$result$records; used <- c(used, file.path(ev, "age-sex-2020.json"))
start <- which(d1$Number == "Queenstown - Total"); stopr <- which(grepl(" - Total$", d1$Number))
stopr <- min(stopr[stopr > start]) - 1L
d1q <- d1[(start + 1):stopr, ]
bands <- c("0_4", "5_9", "10_14", "15_19", "20_24", "25_29", "30_34", "35_39", "40_44", "45_49", "50_54",
           "55_59", "60_64", "65_69", "70_74", "75_79", "80_84", "85_89", "90andOver")
age_sz <- bind_rows(lapply(seq_len(nrow(d1q)), function(i) tibble(
  subzone = title(d1q$Number[i]), band = seq_along(bands) - 1L, residents = num(unlist(d1q[i, paste0("Total_", bands)])))))
sz <- sz |> left_join(age_sz |> group_by(subzone) |> summarise(residents = sum(residents)), by = "subzone")
if (any(is.na(sz$residents))) stop("subzone names do not match D1: ", paste(sz$subzone[is.na(sz$residents)], collapse = ", "))

# Census 2020: residents by subzone and dwelling type; households by dwelling
# type and by size (planning area).
dsz <- records("population-dwelling-type-subzone-census2020.json")
dsz <- dsz[(which(dsz$Number == "Queenstown - Total") + 1):(min(which(grepl(" - Total$", dsz$Number) & seq_len(nrow(dsz)) > which(dsz$Number == "Queenstown - Total"))) - 1), ]
dmap <- c(HDBDwellings_1_and2_RoomFlats1 = "hdb_1_2room", HDBDwellings_3_RoomFlats = "hdb_3room",
          HDBDwellings_4_RoomFlats = "hdb_4room", HDBDwellings_5_RoomandExecutiveFlats = "hdb_5room_exec",
          CondominiumsandOtherApartments = "condo", LandedProperties = "landed", Others = "condo")
dwell_sz <- dsz |> select(Number, all_of(names(dmap))) |>
  pivot_longer(-Number, names_to = "col", values_to = "residents") |>
  mutate(subzone = title(Number), dwelling = dmap[col], residents = num(residents)) |>
  group_by(subzone, dwelling) |> summarise(residents = sum(residents), .groups = "drop")
dh <- records("households-dwelling-type-pa-census2020.json") |> filter(Number == "Queenstown")
if (nrow(dh) != 1) stop("no Queenstown row in households by dwelling type")
dwell_hh <- tibble(col = names(dmap), dwelling = dmap, households = num(unlist(dh[1, names(dmap)]))) |>
  group_by(dwelling) |> summarise(households = sum(households), .groups = "drop")
hs <- records("households-size-pa-census2020.json") |> filter(Number == "Queenstown")
size_cols <- c(`1` = "1Person", `2` = "2Persons", `3` = "3Persons", `4` = "4Persons", `5` = "5Persons",
               `6` = "6Persons", `7` = "7Persons", `8+` = "8orMorePersons")
hh_size <- tibble(size = names(size_cols), households = num(unlist(hs[1, size_cols])))

# HDB residential blocks (geocoded by OneMap) inside Queenstown, with units by
# dwelling type. Rental flats are counted with their room type.
hdb <- read_csv(inp("queenstown-hdb-residential-blocks-derived.csv"), show_col_types = FALSE, col_types = cols(.default = "c")) |>
  filter(residential == "Y", in_queenstown == "TRUE") |>
  mutate(across(c(total_dwelling_units, ends_with("_sold"), ends_with("_rental")), num),
         x = num(x), y = num(y),
         hdb_1_2room = `1room_sold` + `2room_sold` + `1room_rental` + `2room_rental` + studio_apartment_sold,
         hdb_3room = `3room_sold` + `3room_rental` + other_room_rental,
         hdb_4room = `4room_sold`, hdb_5room_exec = `5room_sold` + exec_sold + multigen_sold,
         units = hdb_1_2room + hdb_3room + hdb_4room + hdb_5room_exec) |>
  filter(units > 0) |> select(-subzone)
hdb_sf <- st_as_sf(hdb, coords = c("x", "y"), crs = 3414, remove = FALSE)
hdb_sf <- st_join(hdb_sf, sz |> select(subzone), join = st_within) |> filter(!is.na(subzone))
blocks <- hdb_sf |> st_drop_geometry() |>
  transmute(block_id = row_number(), blk_no, street, subzone, x, y, year_completed = num(year_completed),
            hdb_1_2room, hdb_3room, hdb_4room, hdb_5room_exec, units)

# Land use: private residential parcels are residential parcels with no HDB
# block inside or within 20 m; landed parcels have GPR "LND". Points are
# sampled in proportion to parcel area times gross plot ratio (one point per
# 200 m^2 of permitted floor area, at least one per parcel).
lu <- st_read(inp("queenstown-land-use-derived.geojson"), quiet = TRUE) |> st_transform(3414) |>
  st_make_valid() |> mutate(lu_id = row_number(), area = as.numeric(st_area(geometry)))
gpr_num <- suppressWarnings(as.numeric(lu$GPR))
res_desc <- c("RESIDENTIAL", "RESIDENTIAL WITH COMMERCIAL AT 1ST STOREY", "COMMERCIAL & RESIDENTIAL")
res <- lu |> filter(LU_DESC %in% res_desc)
near_hdb <- lengths(st_is_within_distance(res, hdb_sf, dist = 20)) > 0
priv <- res[!near_hdb, ] |> mutate(kind = ifelse(GPR == "LND", "landed", "condo"),
                                   gpr = ifelse(GPR == "LND", 0.8, ifelse(is.na(suppressWarnings(as.numeric(GPR))), 1.4, suppressWarnings(as.numeric(GPR)))))
priv$n_pts <- pmax(1L, round(priv$area * priv$gpr / 200))
pp_pts <- st_sample(priv, size = priv$n_pts, type = "random", exact = TRUE)
pp_sf <- st_sf(geometry = pp_pts) |> st_join(priv |> select(kind), join = st_within) |>
  st_join(sz |> select(subzone), join = st_within) |> filter(!is.na(subzone), !is.na(kind))
private_points <- pp_sf |> mutate(x = st_coordinates(geometry)[, 1], y = st_coordinates(geometry)[, 2]) |>
  st_drop_geometry() |> select(subzone, kind, x, y)

# Workplace points: parcels zoned for business, commerce, institutions, health,
# education, utilities, transport and the port, sampled in proportion to area
# times plot ratio (unknown or non-numeric plot ratios count as 1.0).
work_desc <- c("COMMERCIAL", "BUSINESS PARK", "BUSINESS PARK - WHITE", "BUSINESS 1", "BUSINESS 2", "WHITE",
               "RESIDENTIAL WITH COMMERCIAL AT 1ST STOREY", "COMMERCIAL & RESIDENTIAL", "EDUCATIONAL INSTITUTION",
               "CIVIC & COMMUNITY INSTITUTION", "HEALTH & MEDICAL CARE", "UTILITY", "TRANSPORT FACILITIES",
               "PORT / AIRPORT", "PLACE OF WORSHIP", "SPORTS & RECREATION", "SPECIAL USE")
wk <- lu |> filter(LU_DESC %in% work_desc) |>
  mutate(gpr = ifelse(is.na(suppressWarnings(as.numeric(GPR))), 1.0, suppressWarnings(as.numeric(GPR))),
         n_pts = pmax(1L, round(area * gpr / 400)))
wk_pts <- st_sample(wk, size = wk$n_pts, type = "random", exact = TRUE)
workplace_points <- st_sf(geometry = wk_pts) |> st_join(wk |> select(lu_desc = LU_DESC), join = st_within) |>
  mutate(x = st_coordinates(geometry)[, 1], y = st_coordinates(geometry)[, 2]) |> st_drop_geometry() |>
  filter(!is.na(lu_desc)) |> select(x, y, lu_desc)

# Schools (MOE, geocoded by postal code) within Queenstown or 1 km of it;
# tertiary sites are the university and polytechnic campuses in Queenstown
# (from the land-use layer's educational parcels in those subzones) plus
# junior colleges and centralized institutes.
moe <- read_csv(inp("queenstown-schools-derived.csv"), show_col_types = FALSE, col_types = cols(.default = "c")) |>
  mutate(x = num(x), y = num(y), d = num(dist_to_qt_boundary_m)) |> filter(d <= 1000)
lvl <- toupper(moe$mainlevel_code)
school_sites <- bind_rows(
  moe |> filter(lvl == "PRIMARY") |> transmute(type = "primary", name = school_name, x, y),
  moe |> filter(startsWith(lvl, "SECONDARY") | startsWith(lvl, "MIXED")) |> transmute(type = "secondary", name = school_name, x, y),
  moe |> filter(lvl %in% c("JUNIOR COLLEGE", "CENTRALISED INSTITUTE")) |> transmute(type = "tertiary", name = school_name, x, y))
campus <- lu |> filter(LU_DESC == "EDUCATIONAL INSTITUTION") |> st_join(sz |> select(subzone), join = st_intersects, largest = TRUE) |>
  filter(tolower(subzone) %in% c("national university of s'pore", "kent ridge", "singapore polytechnic")) |>
  mutate(name = ifelse(tolower(subzone) == "singapore polytechnic", "Singapore Polytechnic", "National University of Singapore")) |>
  group_by(name) |> summarise(geometry = st_union(geometry), .groups = "drop") |> st_point_on_surface()
tertiary_campus <- campus |> mutate(x = st_coordinates(geometry)[, 1], y = st_coordinates(geometry)[, 2]) |>
  st_drop_geometry() |> transmute(type = "tertiary", name, x, y)
pre_sites <- read_csv(inp("queenstown-preschools-derived.csv"), show_col_types = FALSE, col_types = cols(.default = "c")) |>
  mutate(x = num(x), y = num(y), d = num(dist_to_qt_boundary_m)) |> filter(d <= 500) |>
  transmute(type = "preschool", name = CENTRE_NAME, x, y)
sites <- bind_rows(pre_sites, school_sites, tertiary_campus)

# Community venues: existing hawker centres and community clubs within 300 m
# of Queenstown, and licensed supermarkets inside it when geocoded.
hc <- read_csv(inp("queenstown-hawker-centres-derived.csv"), show_col_types = FALSE, col_types = cols(.default = "c")) |>
  mutate(x = num(x), y = num(y), d = num(dist_to_qt_boundary_m)) |> filter(d <= 300, startsWith(STATUS, "Existing"))
cc <- read_csv(inp("queenstown-community-clubs-derived.csv"), show_col_types = FALSE, col_types = cols(.default = "c")) |>
  mutate(x = num(x), y = num(y), d = num(dist_to_qt_boundary_m)) |> filter(d <= 300)
venues <- bind_rows(hc |> transmute(kind = "hawker centre", name = NAME, x, y),
                    cc |> transmute(kind = "community club", name = NAME, x, y))
sm_path <- file.path(qd, "queenstown-supermarkets-derived.csv")
if (file.exists(sm_path)) {
  used <- c(used, sm_path)
  sm <- read_csv(sm_path, show_col_types = FALSE, col_types = cols(.default = "c")) |>
    mutate(x = num(x), y = num(y)) |> filter(in_queenstown == "TRUE")
  sm <- sm[!duplicated(round(cbind(sm$x, sm$y) / 20)), ]
  venues <- bind_rows(venues, sm |> transmute(kind = "supermarket", name = licensee_name, x, y))
}

# Polygon outlines for figures (planning area and subzones).
outline_of <- function(g, level, ids) {
  bind_rows(lapply(seq_along(ids), function(i) {
    cc <- st_coordinates(st_cast(st_geometry(g)[i], "MULTIPOLYGON"))
    tibble(level = level, id = ids[i], part = paste(cc[, "L3"], cc[, "L2"]), x = cc[, "X"], y = cc[, "Y"])
  }))
}
outline <- bind_rows(outline_of(st_sf(geometry = st_geometry(st_union(pa))), "planning_area", "Queenstown"),
                     outline_of(sz, "subzone", sz$subzone))

write_out <- function(df, f) write_csv(df, file.path(out, f))
write_out(sz |> st_drop_geometry() |> select(subzone, area_m2, residents), "subzones.csv")
write_out(age_sz, "age-subzone.csv")
write_out(dwell_sz, "dwelling-subzone.csv")
write_out(dwell_hh, "dwelling-households.csv")
write_out(hh_size, "household-size.csv")
write_out(blocks, "hdb-blocks.csv")
write_out(private_points, "private-points.csv")
write_out(workplace_points, "workplace-points.csv")
write_out(sites, "sites.csv")
write_out(venues, "venues.csv")
write_out(outline, "outline.csv")

files <- list.files(out, "\\.csv$", full.names = TRUE)
manifest <- list(
  script = "model/scripts/data/derive_queenstown.R", created = format(Sys.time(), "%Y-%m-%d %H:%M %Z"), seed = 20201,
  inputs = lapply(unique(used), function(p) list(file = sub(paste0(ev, "/"), "", p), sha256 = digest(file = p, algo = "sha256"))),
  outputs = lapply(files, function(p) list(file = basename(p), rows = nrow(read_csv(p, show_col_types = FALSE)),
                                           sha256 = digest(file = p, algo = "sha256"))))
write_json(manifest, file.path(out, "manifest.json"), auto_unbox = TRUE, pretty = TRUE)

cat("subzones:", nrow(sz), "populated:", sum(sz$residents > 0), "area km2:", round(sum(sz$area_m2) / 1e6, 2), "\n")
cat("HDB blocks:", nrow(blocks), "units:", sum(blocks$units), "\n"); print(colSums(blocks[, c("hdb_1_2room", "hdb_3room", "hdb_4room", "hdb_5room_exec")]))
cat("private points:", nrow(private_points), "\n"); print(table(private_points$kind))
cat("workplace points:", nrow(workplace_points), "\n")
print(table(sites$type)); print(table(venues$kind))
