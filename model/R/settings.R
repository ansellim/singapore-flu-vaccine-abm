# Geography, setting memberships and contact rates.
#
# Coordinates are synthetic (meters in a 4,000 m square) and never represent
# observed Singapore addresses. Memberships are fixed for the whole simulation.

suppressPackageStartupMessages({
  library(dplyr)
  library(Matrix)
})

default_settings_params <- function() {
  list(
    box = 4000,                       # 4 km by 4 km (assumed)
    kernel_L = 1000,                  # distance kernel exp(-d/L), L = 1 km (assumed)
    n_venues = 40L,                   # community venues (assumed)
    workplace_mean_size = 10L,        # assumed
    class_size = c(preschool = 15L, primary = 30L, secondary = 30L, tertiary = 50L),  # assumed
    # Enrollment: preschool ages 3 to 6 at 0.704 (derived for ages 5 to 6: 55,993
    # pre-primary students over 2/5 of the 198,740 residents aged 5 to 9; applied
    # to ages 3 to 4 by assumption); full enrollment at 7 to 16 (assumed); tertiary
    # ages 17 to 24 at 0.652 (derived: 243,617 post-secondary and tertiary students
    # over an estimated 373,678 residents aged 17 to 24).
    enroll_preschool = 55993 / (0.4 * 198740),
    enroll_tertiary = 243617 / (0.6 * 215230 + 244540)
  )
}

# Prem et al. corrected synthetic matrices for Singapore: 16 bands, 0-4 to 75+.
load_prem_sgp <- function() {
  out <- list()
  for (s in c("home", "work", "school", "others")) {
    path <- file.path(evidence_dir(), "prem2021", sprintf("contact_%s.rdata", s))
    meta <- jsonlite::fromJSON(sub("\\.rdata$", ".source.json", path))
    if (!identical(digest::digest(file = path, algo = "sha256"), meta$sha256))
      stop("Checksum mismatch for ", path)
    e <- new.env(); load(path, envir = e)
    m <- get(ls(e)[1], e)[["SGP"]]
    if (!all(dim(m) == c(16, 16))) stop("unexpected Prem matrix dimensions for ", s)
    out[[s]] <- unname(as.matrix(m))
  }
  out
}

prem_band <- function(age) pmin(as.integer(age %/% 5L), 15L) + 1L   # 1..16

# Symmetrize a per-person contact matrix to the synthetic population's band
# sizes so that total contacts between bands a and b agree in both directions.
reciprocal <- function(M, n_band) {
  n <- pmax(n_band, 1)
  T <- M * n                         # total contacts from band a to b
  (T + t(T)) / 2 / n
}

dist_weights <- function(px, py, sx, sy, L) {
  d <- sqrt(outer(px, sx, "-")^2 + outer(py, sy, "-")^2)
  exp(-d / L)
}

sample_by_kernel <- function(px, py, sx, sy, L) {
  W <- dist_weights(px, py, sx, sy, L)
  vapply(seq_along(px), function(i) sample.int(ncol(W), 1, prob = W[i, ]), integer(1))
}

assign_settings <- function(pop, inputs, sp = default_settings_params()) {
  hh <- pop$households; pp <- pop$people
  box <- sp$box; half <- box / 2
  # Households: neighborhood = quadrant; coordinates uniform within it (never on a boundary).
  hh$neighborhood <- sample.int(4L, nrow(hh), replace = TRUE)
  qx <- c(0, half, 0, half); qy <- c(0, 0, half, half)
  hh$x <- qx[hh$neighborhood] + runif(nrow(hh), 1, half - 1)
  hh$y <- qy[hh$neighborhood] + runif(nrow(hh), 1, half - 1)
  pp <- pp |> left_join(hh |> select(hh_id, neighborhood, home_x = x, home_y = y), by = "hh_id")
  n <- nrow(pp)

  # Education.
  u <- runif(n)
  pp$level <- with(pp, case_when(
    fdw ~ NA_character_,
    age >= 3 & age <= 6 & u < sp$enroll_preschool ~ "preschool",
    age >= 7 & age <= 12 ~ "primary",
    age >= 13 & age <= 16 ~ "secondary",
    age >= 17 & age <= 24 & u < sp$enroll_tertiary ~ "tertiary",
    TRUE ~ NA_character_))
  # One preschool/primary site per neighborhood, two secondary sites (west, east),
  # one tertiary site; sites placed at random within their catchment.
  sites <- bind_rows(
    tibble(type = "primary", catch = 1:4, x = qx + runif(4, 200, half - 200), y = qy + runif(4, 200, half - 200)),
    tibble(type = "secondary", catch = 1:2, x = c(runif(1, 200, half - 200), runif(1, half + 200, box - 200)),
           y = runif(2, 200, box - 200)),
    tibble(type = "tertiary", catch = 1L, x = runif(1, 200, box - 200), y = runif(1, 200, box - 200))) |>
    mutate(site_id = row_number())
  site_for <- function(level, nb, x) {
    if (level %in% c("preschool", "primary")) sites$site_id[sites$type == "primary" & sites$catch == nb]
    else if (level == "secondary") sites$site_id[sites$type == "secondary" & sites$catch == (if (x < half) 1L else 2L)]
    else sites$site_id[sites$type == "tertiary"]
  }
  pp$school_site <- NA_integer_
  st <- which(!is.na(pp$level))
  pp$school_site[st] <- mapply(site_for, pp$level[st], pp$neighborhood[st], pp$home_x[st])
  # Classes: same site, level and single year of age, filled to the class size.
  pp$class_id <- NA_integer_
  cls <- pp[st, ] |> mutate(row = st) |> group_by(school_site, level, age) |>
    mutate(k = (row_number() - 1L) %/% sp$class_size[level[1]]) |> ungroup() |>
    mutate(class_key = paste(school_site, level, age, k))
  pp$class_id[cls$row] <- as.integer(factor(cls$class_key))

  # Work: residents aged 15+ not in education, with probability equal to the
  # 2020 labour force participation rate for their sex and age band (observed;
  # treated as the probability of a regular workplace, which slightly overstates
  # employment because participation includes the unemployed).
  lf <- inputs$lfpr
  rate <- vapply(seq_len(n), function(i) {
    if (pp$fdw[i] || pp$age[i] < 15 || !is.na(pp$level[i])) return(0)
    r <- lf$rate[lf$sex == pp$sex[i] & pp$age[i] >= lf$age_lo & pp$age[i] <= lf$age_hi]
    if (length(r) != 1) stop("no unique LFPR row for age ", pp$age[i])
    r
  }, numeric(1))
  pp$worker <- runif(n) < rate
  w <- which(pp$worker)
  n_wp <- max(1L, ceiling(length(w) / sp$workplace_mean_size))
  wp <- tibble(workplace_id = seq_len(n_wp), x = runif(n_wp, 1, box - 1), y = runif(n_wp, 1, box - 1))
  pp$workplace_id <- NA_integer_
  pp$workplace_id[w] <- sample_by_kernel(pp$home_x[w], pp$home_y[w], wp$x, wp$y, sp$kernel_L)

  # Community venues: everyone, distance-weighted.
  ven <- tibble(venue_id = seq_len(sp$n_venues), x = runif(sp$n_venues, 1, box - 1),
                y = runif(sp$n_venues, 1, box - 1))
  pp$venue_id <- sample_by_kernel(pp$home_x, pp$home_y, ven$x, ven$y, sp$kernel_L)

  pp$band <- prem_band(pp$age)
  list(people = pp, households = hh, sites = sites, workplaces = wp, venues = ven,
       settings_params = sp)
}

# Geographically shuffled control: destinations are
# permuted among individuals of the same kind, preserving every group's size,
# while breaking the link between home location and destination.
shuffle_destinations <- function(world) {
  pp <- world$people
  w <- which(!is.na(pp$workplace_id))
  pp$workplace_id[w] <- pp$workplace_id[w][sample.int(length(w))]
  pp$venue_id <- pp$venue_id[sample.int(nrow(pp))]
  # Classes: permute class memberships among students of the same level and age.
  for (key in unique(paste(pp$level, pp$age)[!is.na(pp$class_id)])) {
    idx <- which(!is.na(pp$class_id) & paste(pp$level, pp$age) == key)
    if (length(idx) > 1) pp$class_id[idx] <- pp$class_id[idx][sample.int(length(idx))]
  }
  world$people <- pp
  world$shuffled <- TRUE
  world
}

# Per-person daily contact rates derived from the Prem matrices for the
# synthetic population: school and work contacts per attendee (the published
# per-capita rates divided by the synthetic attendance share in each band),
# community contacts as a reciprocal band-by-band matrix.
contact_rates <- function(world, prem) {
  pp <- world$people
  nb <- tabulate(pp$band, nbins = 16)
  att_school <- tabulate(pp$band[!is.na(pp$class_id)], nbins = 16) / pmax(nb, 1)
  att_work <- tabulate(pp$band[pp$worker], nbins = 16) / pmax(nb, 1)
  per_cap_school <- rowSums(prem$school); per_cap_work <- rowSums(prem$work)
  list(
    school = ifelse(att_school > 0, per_cap_school / pmax(att_school, 1e-9), 0),
    work = ifelse(att_work > 0, per_cap_work / pmax(att_work, 1e-9), 0),
    community = reciprocal(prem$others, nb),
    gathering = rowSums(prem$others)        # domestic workers' rest-day contacts (assumed equal to community totals)
  )
}
