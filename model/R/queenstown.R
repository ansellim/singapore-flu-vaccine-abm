# Part 2 geography: the Queenstown planning area (URA Master Plan 2019).
#
# Model-ready inputs are derived once from the stored public files by
# scripts/data/derive_queenstown.R (which needs sf) and stored as CSV in
# planning-evidence/queenstown/model/, so the simulation servers need no
# spatial libraries. Coordinates are SVY21 (EPSG:3414) meters.

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
})

# A4_QT_MODEL_DIR selects another set of derived inputs (for example the
# superseded inputs in queenstown/model_v1_superseded).
qt_dir <- function() file.path(evidence_dir(), "queenstown", Sys.getenv("A4_QT_MODEL_DIR", unset = "model"))

read_qt_csv <- function(name) {
  path <- file.path(qt_dir(), name)
  if (!file.exists(path)) stop("Missing Queenstown input: ", path)
  read_csv(path, show_col_types = FALSE, progress = FALSE)
}

dwelling_types <- c("hdb_1_2room", "hdb_3room", "hdb_4room", "hdb_5room_exec", "condo", "landed")

# Floor-area ranges (m^2) by dwelling type. HDB ranges span the typical
# internal floor areas of each flat type; private ranges are assumed.
dwelling_floor_range <- list(hdb_1_2room = c(30, 47), hdb_3room = c(60, 75), hdb_4room = c(85, 105),
                             hdb_5room_exec = c(105, 150), condo = c(60, 150), landed = c(150, 400))

queenstown_inputs <- function() {
  list(
    subzones = read_qt_csv("subzones.csv"),          # subzone, area_m2
    age_subzone = read_qt_csv("age-subzone.csv"),    # subzone, band (0..18), residents
    dwell_subzone = read_qt_csv("dwelling-subzone.csv"),   # subzone, dwelling, residents
    dwell_households = read_qt_csv("dwelling-households.csv"),   # dwelling, households
    hh_size = read_qt_csv("household-size.csv"),     # size (1..8+), households
    blocks = read_qt_csv("hdb-blocks.csv"),          # block_id, subzone, x, y, units by dwelling type
    private_points = read_qt_csv("private-points.csv"),   # subzone, kind (condo/landed), x, y
    workplace_points = read_qt_csv("workplace-points.csv"),   # x, y, lu_desc
    sites = read_qt_csv("sites.csv"),                # type, name, x, y
    venues = read_qt_csv("venues.csv"),              # kind, name, x, y
    outline = read_qt_csv("outline.csv"),            # polygon vertices: level, id, part, x, y
    area_m2 = sum(read_qt_csv("subzones.csv")$area_m2)
  )
}

# Annealing assignment of households to (subzone, dwelling type) cells so that
# the synthetic population matches three Census 2020 tables at once: residents
# by subzone and 5-year age band, residents by subzone and dwelling type, and
# households by dwelling type. Every table is weighted equally.
assign_cells <- function(hh_band, hh_res, qt, iters) {
  sz <- sort(unique(qt$age_subzone$subzone[qt$age_subzone$residents > 0]))
  nz <- length(sz); nd <- length(dwelling_types); H <- nrow(hh_band)
  scale <- sum(hh_res) / sum(qt$age_subzone$residents)
  T_age <- matrix(0, nz, 19)
  a <- qt$age_subzone |> filter(subzone %in% sz)
  T_age[cbind(match(a$subzone, sz), a$band + 1L)] <- a$residents * scale
  T_dr <- matrix(0, nz, nd)
  d <- qt$dwell_subzone |> filter(subzone %in% sz)
  T_dr[cbind(match(d$subzone, sz), match(d$dwelling, dwelling_types))] <- d$residents * scale
  T_dh <- qt$dwell_households$households[match(dwelling_types, qt$dwell_households$dwelling)]
  T_dh <- T_dh / sum(T_dh) * H
  w_age <- 1 / length(T_age); w_dr <- 1 / length(T_dr); w_dh <- 1 / length(T_dh)
  # Start: subzone in proportion to residents, dwelling type in proportion to
  # the subzone's dwelling-type residents.
  z <- sample.int(nz, H, replace = TRUE, prob = rowSums(T_dr))
  dt <- vapply(z, function(k) sample.int(nd, 1, prob = T_dr[k, ] + 1e-9), integer(1))
  O_age <- matrix(0, nz, 19); O_dr <- matrix(0, nz, nd); O_dh <- numeric(nd)
  for (h in seq_len(H)) {
    O_age[z[h], ] <- O_age[z[h], ] + hh_band[h, ]
    O_dr[z[h], dt[h]] <- O_dr[z[h], dt[h]] + hh_res[h]
    O_dh[dt[h]] <- O_dh[dt[h]] + 1
  }
  sq <- function(o, t) (o - t)^2 / (t + 1)
  temps <- 1 * (1e-3 / 1)^(seq_len(iters) / iters)
  hs <- sample.int(H, iters, replace = TRUE)
  nzs <- sample.int(nz, iters, replace = TRUE, prob = rowSums(T_dr))
  nds <- sample.int(nd, iters, replace = TRUE, prob = T_dh)
  move_z <- runif(iters) < 0.5
  u <- runif(iters)
  for (it in seq_len(iters)) {
    h <- hs[it]; z0 <- z[h]; d0 <- dt[h]
    z1 <- if (move_z[it]) nzs[it] else z0
    d1 <- if (move_z[it]) d0 else nds[it]
    if (z1 == z0 && d1 == d0) next
    b <- hh_band[h, ]; r <- hh_res[h]
    delta <- 0
    if (z1 != z0) {
      delta <- delta + w_age * (sum(sq(O_age[z0, ] - b, T_age[z0, ]) - sq(O_age[z0, ], T_age[z0, ])) +
                                sum(sq(O_age[z1, ] + b, T_age[z1, ]) - sq(O_age[z1, ], T_age[z1, ])))
    }
    delta <- delta + w_dr * (sq(O_dr[z0, d0] - r, T_dr[z0, d0]) - sq(O_dr[z0, d0], T_dr[z0, d0]) +
                             sq(O_dr[z1, d1] + r, T_dr[z1, d1]) - sq(O_dr[z1, d1], T_dr[z1, d1]))
    if (d1 != d0) {
      delta <- delta + w_dh * (sq(O_dh[d0] - 1, T_dh[d0]) - sq(O_dh[d0], T_dh[d0]) +
                               sq(O_dh[d1] + 1, T_dh[d1]) - sq(O_dh[d1], T_dh[d1]))
    }
    if (delta <= 0 || u[it] < exp(-delta / temps[it])) {
      if (z1 != z0) { O_age[z0, ] <- O_age[z0, ] - b; O_age[z1, ] <- O_age[z1, ] + b }
      O_dr[z0, d0] <- O_dr[z0, d0] - r; O_dr[z1, d1] <- O_dr[z1, d1] + r
      O_dh[d0] <- O_dh[d0] - 1; O_dh[d1] <- O_dh[d1] + 1
      z[h] <- z1; dt[h] <- d1
    }
  }
  sae <- c(age = sum(abs(O_age - T_age)) / sum(T_age), dwelling_residents = sum(abs(O_dr - T_dr)) / sum(T_dr),
           dwelling_households = sum(abs(O_dh - T_dh)) / sum(T_dh))
  list(subzone = sz[z], dwelling = dwelling_types[dt], sae = sae)
}

queenstown_layout <- function(qt, sa_iters_per_household = 80L) {
  list(
    name = "queenstown",
    neighborhoods = sort(unique(qt$age_subzone$subzone[qt$age_subzone$residents > 0])),
    place_households = function(hh, people) {
      res <- people |> filter(resident)
      bandm <- table(factor(res$hh_id, levels = hh$hh_id), factor(age_band_5(res$age), levels = 0:18))
      hh_band <- matrix(as.numeric(bandm), nrow = nrow(hh))
      cells <- assign_cells(hh_band, hh$residents, qt, sa_iters_per_household * nrow(hh))
      hh$subzone <- cells$subzone; hh$dwelling <- cells$dwelling
      hh$x <- NA_real_; hh$y <- NA_real_; hh$block_id <- NA_integer_
      # HDB households: a block in their subzone with flats of their type,
      # chosen in proportion to its number of such flats; if the subzone has
      # none of that type, any HDB block in the subzone; if none, the nearest
      # subzone's blocks of that type.
      blocks <- qt$blocks
      hdb <- which(startsWith(hh$dwelling, "hdb"))
      for (key in unique(paste(hh$subzone[hdb], hh$dwelling[hdb]))) {
        idx <- hdb[paste(hh$subzone[hdb], hh$dwelling[hdb]) == key]
        s <- hh$subzone[idx[1]]; dtp <- hh$dwelling[idx[1]]
        cand <- blocks |> filter(subzone == s, .data[[dtp]] > 0); wt <- cand[[dtp]]
        if (!nrow(cand)) { cand <- blocks |> filter(subzone == s, units > 0); wt <- cand$units }
        if (!nrow(cand)) { cand <- blocks |> filter(.data[[dtp]] > 0); wt <- cand[[dtp]] }
        j <- sample.int(nrow(cand), length(idx), replace = TRUE, prob = wt)
        hh$block_id[idx] <- cand$block_id[j]
        # Households in one block are spread over its footprint (up to 15 m).
        hh$x[idx] <- cand$x[j] + runif(length(idx), -15, 15)
        hh$y[idx] <- cand$y[j] + runif(length(idx), -15, 15)
      }
      # Private households: a random point on a private residential parcel of
      # their kind in their subzone (points were sampled in proportion to
      # parcel area times gross plot ratio); if none, any private point there;
      # if none, any private point of their kind in Queenstown.
      pv <- which(!startsWith(hh$dwelling, "hdb"))
      pts <- qt$private_points
      for (key in unique(paste(hh$subzone[pv], hh$dwelling[pv]))) {
        idx <- pv[paste(hh$subzone[pv], hh$dwelling[pv]) == key]
        s <- hh$subzone[idx[1]]; kind <- hh$dwelling[idx[1]]
        cand <- pts |> filter(subzone == s, kind == !!kind)
        if (!nrow(cand)) cand <- pts |> filter(subzone == s)
        if (!nrow(cand)) cand <- pts |> filter(kind == !!kind)
        j <- sample.int(nrow(cand), length(idx), replace = TRUE)
        hh$x[idx] <- cand$x[j]; hh$y[idx] <- cand$y[j]
      }
      # Floor area follows the dwelling type at the household's address.
      rng <- dwelling_floor_range[hh$dwelling]
      hh$floor_area <- vapply(rng, function(r) runif(1, r[1], r[2]), numeric(1))
      hh$area_per_occupant <- hh$floor_area / hh$occupants
      hh$neighborhood <- match(hh$subzone, sort(unique(qt$age_subzone$subzone[qt$age_subzone$residents > 0])))
      attr(hh, "cell_fit") <- cells$sae
      hh
    },
    sites = qt$sites |> select(type, x, y, name),
    workplace_points = function(m) {
      j <- sample.int(nrow(qt$workplace_points), m, replace = TRUE)
      qt$workplace_points[j, c("x", "y")] |> mutate(x = x + runif(m, -10, 10), y = y + runif(m, -10, 10))
    },
    venue_sites = qt$venues |> select(x, y, kind, name),
    boundary = qt$outline
  )
}

# Part 1 layout matched to Queenstown: the same land area, one neighborhood per
# populated subzone and the same numbers of school, tertiary and venue sites.
square_layout_for <- function(qt) {
  n_sites <- table(factor(qt$sites$type, levels = c("preschool", "primary", "secondary", "tertiary")))
  square_layout(qt$area_m2, K = sum(qt$subzones$residents > 0), n_sites = as.list(n_sites),
                n_venue_sites = nrow(qt$venues))
}
