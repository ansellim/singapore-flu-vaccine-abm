#!/usr/bin/env Rscript
# Build Queenstown-clipped derived geography files from the raw inputs in
# planning-evidence/queenstown/ (downloaded by download_queenstown_inputs.py,
# geocoded by geocode_queenstown_inputs.py). All outputs are EPSG:3414 (SVY21).
#
# Usage (from the assessment4 directory):
#   Rscript model/scripts/data/build_queenstown_geography.R planning-evidence/queenstown [step ...]
# Steps: polygons landuse hdb schools preschools venues supermarkets (default: all).
# Each step stops with an error if its raw input is missing or fails a check.
#
# Each output gets a sidecar <name>.source.json: source "derived", the inputs
# with their sha256, this script, the exact method, feature/row count, sha256.

suppressPackageStartupMessages({
  library(sf)
  library(dplyr)
  library(jsonlite)
  library(digest)
})

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1) stop("Usage: build_queenstown_geography.R <evidence_dir> [step ...]")
ev <- args[1]
steps <- if (length(args) > 1) args[-1] else
  c("polygons", "landuse", "hdb", "schools", "preschools", "venues", "supermarkets")

SCRIPT <- "model/scripts/data/build_queenstown_geography.R"
QT <- "QUEENSTOWN"
BUFFER_M <- 2000
sf_use_s2(FALSE)  # all geometry work is planar in SVY21 metres

p <- function(...) file.path(ev, ...)
sha <- function(path) digest(file = path, algo = "sha256")

write_sidecar <- function(out, inputs, method, purpose, count_key, n) {
  side <- list(
    source = "derived",
    derived_from = lapply(inputs, function(f) list(file = basename(f), sha256 = sha(f))),
    script = SCRIPT,
    crs = "EPSG:3414 (SVY21)",
    retrieval_date = as.character(Sys.Date()),
    method = method,
    sha256 = sha(out),
    purpose = purpose
  )
  side[[count_key]] <- n
  writeLines(toJSON(side, auto_unbox = TRUE, pretty = TRUE),
             sub("\\.(geojson|csv)$", ".source.json", out))
  message(basename(out), ": ", count_key, " = ", n)
}

write_geojson <- function(x, out) {
  if (file.exists(out)) file.remove(out)
  st_write(x, out, driver = "GeoJSON", quiet = TRUE,
           layer_options = c("RFC7946=NO", "WRITE_NAME=NO"))
}

read_raw <- function(name) {
  f <- p(name)
  if (!file.exists(f)) stop("Missing raw input: ", f)
  x <- st_read(f, quiet = TRUE)
  st_transform(st_zm(x, drop = TRUE), 3414)
}

# Planning-area and subzone polygons are needed by every step.
subzones_all <- function() {
  read_raw("mp2019-subzone-boundary-nosea.geojson") |>
    select(SUBZONE_N, SUBZONE_C, PLN_AREA_N, PLN_AREA_C, REGION_N) |>
    st_make_valid()
}
qt_polygon <- function() {
  pa <- read_raw("mp2019-planning-area-boundary-nosea.geojson") |> filter(PLN_AREA_N == QT)
  if (nrow(pa) != 1) stop("Expected exactly one QUEENSTOWN planning-area feature, got ", nrow(pa))
  st_make_valid(pa) |> select(PLN_AREA_N, PLN_AREA_C, REGION_N)
}

SZ <- subzones_all()
PA <- qt_polygon()
PA_BUF <- st_buffer(PA, BUFFER_M)

# Tag points (sf, EPSG:3414) with subzone, planning area, inside-Queenstown flag
# and distance to the Queenstown boundary (0 inside).
tag_points <- function(pts) {
  pts <- st_join(pts, SZ |> select(subzone = SUBZONE_N, subzone_code = SUBZONE_C,
                                   planning_area = PLN_AREA_N), join = st_within)
  inside <- lengths(st_within(pts, PA)) > 0
  d <- as.numeric(st_distance(pts, st_boundary(PA)))
  pts$in_queenstown <- inside
  pts$dist_to_qt_boundary_m <- round(ifelse(inside, 0, d), 1)
  xy <- st_coordinates(pts)
  pts$x <- round(xy[, 1], 2)
  pts$y <- round(xy[, 2], 2)
  pts
}

write_points_csv <- function(pts, out) {
  df <- st_drop_geometry(pts) |> relocate(x, y, subzone, subzone_code, planning_area,
                                          in_queenstown, dist_to_qt_boundary_m)
  write.csv(df, out, row.names = FALSE, na = "")
  nrow(df)
}

# Parse the HTML attribute table that some data.gov.sg KML-derived GeoJSON
# files carry in a Description property into named columns.
parse_description <- function(desc) {
  rows <- lapply(desc, function(h) {
    k <- regmatches(h, gregexpr("<th>[^<]*</th>", h))[[1]]
    v <- regmatches(h, gregexpr("<td>[^<]*</td>", h))[[1]]
    k <- gsub("</?th>", "", k)
    v <- gsub("</?td>", "", v)
    if (length(k) != length(v)) stop("Malformed Description table: ", substr(h, 1, 200))
    setNames(as.list(trimws(v)), trimws(k))
  })
  bind_rows(rows)
}
flatten_props <- function(x) {
  if ("Description" %in% names(x)) {
    attrs <- parse_description(x$Description)
    x <- bind_cols(select(x, -any_of(c("Name", "Description"))), attrs)
  }
  x
}

# ---- Steps --------------------------------------------------------------

step_polygons <- function() {
  out <- p("queenstown-planning-area-derived.geojson")
  write_geojson(PA, out)
  write_sidecar(out, c(p("mp2019-planning-area-boundary-nosea.geojson")),
                "Feature with PLN_AREA_N == 'QUEENSTOWN' from the MP2019 planning-area layer, Z dropped, made valid, transformed to EPSG:3414.",
                "Queenstown study-area boundary.", "features", nrow(PA))
  sz <- SZ |> filter(PLN_AREA_N == QT)
  sz$area_m2 <- round(as.numeric(st_area(sz)), 1)
  out <- p("queenstown-subzones-derived.geojson")
  write_geojson(sz, out)
  write_sidecar(out, c(p("mp2019-subzone-boundary-nosea.geojson")),
                "Features with PLN_AREA_N == 'QUEENSTOWN' from the MP2019 subzone layer (columns SUBZONE_N, SUBZONE_C, PLN_AREA_N, PLN_AREA_C, REGION_N), Z dropped, made valid, transformed to EPSG:3414; area_m2 computed in SVY21.",
                "Queenstown subzone polygons; join keys to Census 2020 subzone tables (age-sex-2020.json).",
                "features", nrow(sz))
}

step_landuse <- function() {
  lu <- read_raw("mp2019-land-use.geojson") |>
    select(LU_DESC, LU_TEXT, GPR, OBJECTID)
  cand <- lu[lengths(st_intersects(lu, PA)) > 0, ]
  cand <- st_make_valid(cand)
  clip <- suppressWarnings(st_intersection(cand, PA |> select()))
  clip <- st_collection_extract(clip, "POLYGON")
  clip$area_m2 <- round(as.numeric(st_area(clip)), 1)
  clip <- clip |> filter(area_m2 > 1)
  out <- p("queenstown-land-use-derived.geojson")
  write_geojson(clip, out)
  write_sidecar(out, c(p("mp2019-land-use.geojson"), p("mp2019-planning-area-boundary-nosea.geojson")),
                "MP2019 land-use polygons (columns LU_DESC, LU_TEXT, GPR, OBJECTID) transformed to EPSG:3414, made valid, intersected with the Queenstown planning-area polygon (planar, sf_use_s2(FALSE)); only polygon parts kept; slivers of 1 m2 or less dropped; area_m2 is the clipped area.",
                "Queenstown land-use zoning for workplace and amenity placement.", "features", nrow(clip))
}

step_hdb <- function() {
  src <- p("hdb-blocks-geocoded-derived.csv")
  if (!file.exists(src)) stop("Missing ", src)
  h <- read.csv(src, colClasses = "character", check.names = FALSE)
  n_cand <- nrow(h)
  h <- h |> filter(residential == "Y", match_quality %in% c("exact", "ambiguous"))
  pts <- st_as_sf(h, coords = c("svy21_x", "svy21_y"), crs = 3414, remove = FALSE)
  pts <- tag_points(pts) |> filter(in_queenstown)
  num_cols <- c("total_dwelling_units", grep("_(sold|rental)$", names(pts), value = TRUE),
                "max_floor_lvl", "year_completed")
  for (cc in num_cols) pts[[cc]] <- as.integer(pts[[cc]])
  pts <- pts |> select(-svy21_x, -svy21_y)
  out <- p("queenstown-hdb-residential-blocks-derived.csv")
  n <- write_points_csv(pts, out)
  write_sidecar(out, c(src, p("mp2019-planning-area-boundary-nosea.geojson"), p("mp2019-subzone-boundary-nosea.geojson")),
                paste0("From hdb-blocks-geocoded-derived.csv (", n_cand, " blocks in candidate HDB towns): kept residential == 'Y' and match_quality exact or ambiguous; points at OneMap SVY21 X/Y; kept points within the Queenstown planning-area polygon; subzone from point-in-polygon with MP2019 subzones. x, y are SVY21 metres. All HDB Property Information columns kept unchanged (dwelling-unit counts as integers)."),
                "Household locations and dwelling units by flat type for Queenstown.", "rows", n)
}

step_schools <- function() {
  src <- p("moe-schools-geocoded-derived.csv")
  if (!file.exists(src)) stop("Missing ", src)
  s <- read.csv(src, colClasses = "character", check.names = FALSE) |> filter(match_quality %in% c("exact", "ambiguous"))
  pts <- st_as_sf(s, coords = c("svy21_x", "svy21_y"), crs = 3414, remove = FALSE)
  pts <- pts[lengths(st_intersects(pts, PA_BUF)) > 0, ]
  pts <- tag_points(pts) |> select(-svy21_x, -svy21_y)
  keep <- c("school_name", "address", "postal_code", "mainlevel_code", "type_code", "nature_code",
            "session_code", "zone_code", "dgp_code",
            "match_quality", "matched_address", "latitude", "longitude")
  pts <- pts |> select(x, y, subzone, subzone_code, planning_area, in_queenstown,
                       dist_to_qt_boundary_m, any_of(keep))
  out <- p("queenstown-schools-derived.csv")
  n <- write_points_csv(pts, out)
  write_sidecar(out, c(src, p("mp2019-planning-area-boundary-nosea.geojson"), p("mp2019-subzone-boundary-nosea.geojson")),
                "MOE schools from moe-schools-geocoded-derived.csv with match_quality exact or ambiguous, located at OneMap SVY21 X/Y, kept when within 2000 m of the Queenstown planning-area polygon (st_buffer 2000 m, planar). in_queenstown flags points inside the polygon; dist_to_qt_boundary_m is 0 inside. Subset of MOE columns kept (school_name, address, postal_code, mainlevel_code, type_code, nature_code, session_code, zone_code, dgp_code).",
                "School locations for school assignment of Queenstown children.", "rows", n)
}

step_preschools <- function() {
  ps <- read_raw("ecda-preschools-location.geojson") |> flatten_props()
  ps <- ps[lengths(st_intersects(ps, PA_BUF)) > 0, ]
  pts <- tag_points(ps)
  out <- p("queenstown-preschools-derived.csv")
  n <- write_points_csv(pts, out)
  write_sidecar(out, c(p("ecda-preschools-location.geojson"), p("mp2019-planning-area-boundary-nosea.geojson"), p("mp2019-subzone-boundary-nosea.geojson")),
                "ECDA preschool points (Description HTML attribute table, if present, parsed into columns), Z dropped, transformed to EPSG:3414, kept when within 2000 m of the Queenstown planning-area polygon. in_queenstown and dist_to_qt_boundary_m as for schools.",
                "Preschool locations for assignment of Queenstown children aged under 7.", "rows", n)
}

step_venue <- function(raw, out_name, label) {
  v <- read_raw(raw) |> flatten_props()
  v <- v[lengths(st_intersects(v, PA_BUF)) > 0, ]
  pts <- tag_points(v)
  out <- p(out_name)
  n <- write_points_csv(pts, out)
  write_sidecar(out, c(p(raw), p("mp2019-planning-area-boundary-nosea.geojson"), p("mp2019-subzone-boundary-nosea.geojson")),
                paste0(label, " points (Description HTML attribute table, if present, parsed into columns), Z dropped, transformed to EPSG:3414, kept when within 2000 m of the Queenstown planning-area polygon; filter in_queenstown == TRUE for venues inside Queenstown."),
                paste0(label, " locations: community mixing venues."), "rows", n)
}

step_venues <- function() {
  step_venue("nea-hawker-centres.geojson", "queenstown-hawker-centres-derived.csv", "NEA hawker centre")
  step_venue("pa-community-clubs.geojson", "queenstown-community-clubs-derived.csv", "People's Association community club")
}

step_supermarkets <- function() {
  src <- p("supermarkets-geocoded-derived.csv")
  if (!file.exists(src)) stop("Missing ", src)
  s <- read.csv(src, colClasses = "character", check.names = FALSE) |> filter(match_quality %in% c("exact", "ambiguous"))
  pts <- st_as_sf(s, coords = c("svy21_x", "svy21_y"), crs = 3414, remove = FALSE)
  pts <- pts[lengths(st_intersects(pts, PA_BUF)) > 0, ]
  pts <- tag_points(pts) |> select(-svy21_x, -svy21_y)
  out <- p("queenstown-supermarkets-derived.csv")
  n <- write_points_csv(pts, out)
  write_sidecar(out, c(src, p("mp2019-planning-area-boundary-nosea.geojson"), p("mp2019-subzone-boundary-nosea.geojson")),
                "NEA supermarket licences from supermarkets-geocoded-derived.csv with match_quality exact or ambiguous, at OneMap SVY21 X/Y, kept when within 2000 m of the Queenstown planning-area polygon.",
                "Supermarket locations: community mixing venues.", "rows", n)
}

for (s in steps) {
  message("== step ", s)
  get(paste0("step_", s))()
}
