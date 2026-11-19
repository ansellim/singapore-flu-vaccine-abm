# Full-scale geographies (Parts 1 and 2 of the study).
#
# Part 1 places the population of the Queenstown planning area in a synthetic
# square of the same land area, divided into as many neighborhoods as
# Queenstown has populated subzones. Part 2 places the same population on the
# real Queenstown geography (Master Plan 2019 subzones, HDB blocks, schools,
# hawker centres and community clubs; see queenstown.R). Both parts share the
# setting rules below and differ only in where homes and destinations are, so
# a comparison between them isolates the effect of geography.
#
# Group sizes are those of the original 5,000-resident community: classes of
# 30 (15 in preschool), workplaces of 10, community-venue groups of about 125
# and domestic-worker gatherings of about 250. A real venue such as a hawker
# centre therefore hosts several venue groups, each the set of regular users
# who mix with one another.

suppressPackageStartupMessages({
  library(dplyr)
})

default_extension_params <- function() {
  sp <- default_settings_params()
  sp$box <- NULL
  sp$n_venues <- NULL
  c(sp, list(
    venue_group_size = 125L,       # matches 5,000 residents over 40 venues (assumed)
    gathering_group_size = 250L,   # matches the single gathering of the original community (assumed)
    kernel_chunk = 2000L           # rows per chunk when sampling by distance kernel
  ))
}

# Distance-kernel choice processed in chunks of rows, so memory stays bounded
# at full scale. Each row's draw is the same call as in sample_by_kernel().
sample_by_kernel_chunked <- function(px, py, sx, sy, L, chunk = 2000L) {
  out <- integer(length(px))
  for (s in seq(1L, length(px), by = chunk)) {
    idx <- s:min(length(px), s + chunk - 1L)
    W <- dist_weights(px[idx], py[idx], sx, sy, L)
    out[idx] <- vapply(seq_along(idx), function(i) sample.int(ncol(W), 1, prob = W[i, ]), integer(1))
  }
  out
}

nearest_site <- function(px, py, sx, sy, chunk = 2000L) {
  out <- integer(length(px))
  for (s in seq(1L, length(px), by = chunk)) {
    idx <- s:min(length(px), s + chunk - 1L)
    d2 <- outer(px[idx], sx, "-")^2 + outer(py[idx], sy, "-")^2
    out[idx] <- max.col(-d2, ties.method = "first")
  }
  out
}

# Split the members of each site into groups of about `size`, at random.
split_groups <- function(site, size) {
  out <- integer(length(site))
  next_id <- 0L
  for (s in sort(unique(site[!is.na(site)]))) {
    idx <- which(site == s)
    k <- max(1L, round(length(idx) / size))
    g <- sample(rep_len(seq_len(k), length(idx)))
    out[idx] <- next_id + g
    next_id <- next_id + k
  }
  out[is.na(site)] <- NA_integer_
  out
}

# Assign settings on a layout. A layout is a list with
#   place_households(hh, people) -> hh with neighborhood, x, y (and optionally floor
#                           area columns that replace the synthesized ones),
#   sites: tibble(type in preschool/primary/secondary/tertiary, x, y),
#   workplace_points(n) -> tibble(x, y),
#   venue_sites: tibble(x, y),
#   name, neighborhoods (labels), boundary (for maps; optional).
assign_settings_layout <- function(pop, inputs, layout, sp = default_extension_params()) {
  hh <- layout$place_households(pop$households, pop$people)
  pp <- pop$people |>
    left_join(hh |> select(hh_id, neighborhood, home_x = x, home_y = y), by = "hh_id")
  n <- nrow(pp)

  # Education (rates as in the original community).
  u <- runif(n)
  pp$level <- with(pp, case_when(
    fdw ~ NA_character_,
    age >= 3 & age <= 6 & u < sp$enroll_preschool ~ "preschool",
    age >= 7 & age <= 12 ~ "primary",
    age >= 13 & age <= 16 ~ "secondary",
    age >= 17 & age <= 24 & u < sp$enroll_tertiary ~ "tertiary",
    TRUE ~ NA_character_))
  sites <- layout$sites |> mutate(site_id = row_number())
  pp$school_site <- NA_integer_
  # Preschool and primary: nearest site (primary school admission in Singapore
  # gives priority by home distance). Secondary and tertiary: distance kernel.
  for (lv in c("preschool", "primary", "secondary", "tertiary")) {
    st <- which(pp$level == lv)
    if (!length(st)) next
    cand <- sites |> filter(type == lv)
    if (!nrow(cand)) stop("layout has no ", lv, " site")
    j <- if (lv %in% c("preschool", "primary"))
      nearest_site(pp$home_x[st], pp$home_y[st], cand$x, cand$y, sp$kernel_chunk)
    else sample_by_kernel_chunked(pp$home_x[st], pp$home_y[st], cand$x, cand$y, sp$kernel_L, sp$kernel_chunk)
    pp$school_site[st] <- cand$site_id[j]
  }
  st <- which(!is.na(pp$level))
  pp$class_id <- NA_integer_
  cls <- pp[st, ] |> mutate(row = st) |> group_by(school_site, level, age) |>
    mutate(k = (row_number() - 1L) %/% sp$class_size[level[1]]) |> ungroup() |>
    mutate(class_key = paste(school_site, level, age, k))
  pp$class_id[cls$row] <- as.integer(factor(cls$class_key))

  # Work (as in the original community), vectorized over the LFPR table.
  lf <- inputs$lfpr
  rate <- numeric(n)
  elig <- which(!pp$fdw & pp$age >= 15 & is.na(pp$level))
  for (r in seq_len(nrow(lf))) {
    m <- elig[pp$sex[elig] == lf$sex[r] & pp$age[elig] >= lf$age_lo[r] & pp$age[elig] <= lf$age_hi[r]]
    rate[m] <- lf$rate[r]
  }
  if (any(rate[elig] == 0 & pp$age[elig] < 100)) stop("LFPR rows do not cover every eligible age")
  pp$worker <- runif(n) < rate
  w <- which(pp$worker)
  n_wp <- max(1L, ceiling(length(w) / sp$workplace_mean_size))
  wp <- layout$workplace_points(n_wp) |> mutate(workplace_id = row_number(), .before = 1)
  pp$workplace_id <- NA_integer_
  pp$workplace_id[w] <- sample_by_kernel_chunked(pp$home_x[w], pp$home_y[w], wp$x, wp$y,
                                                 sp$kernel_L, sp$kernel_chunk)

  # Community venues: a site chosen by distance kernel, then a group within it.
  vs <- layout$venue_sites |> mutate(site = row_number())
  pp$venue_site <- sample_by_kernel_chunked(pp$home_x, pp$home_y, vs$x, vs$y, sp$kernel_L, sp$kernel_chunk)
  pp$venue_id <- split_groups(pp$venue_site, sp$venue_group_size)
  ven <- pp |> distinct(venue_id, venue_site) |> arrange(venue_id) |>
    left_join(vs, by = c("venue_site" = "site"))

  # Domestic workers' rest-day gatherings: random groups of about 250.
  pp$gathering_id <- NA_integer_
  f <- which(pp$fdw)
  if (length(f)) {
    k <- max(1L, round(length(f) / sp$gathering_group_size))
    pp$gathering_id[f] <- sample(rep_len(seq_len(k), length(f)))
  }

  pp$band <- prem_band(pp$age)
  list(people = pp, households = hh, sites = sites, workplaces = wp, venues = ven,
       venue_sites = vs, settings_params = sp, geography = layout$name,
       neighborhoods = layout$neighborhoods, boundary = layout$boundary)
}

# ---------------------------------------------------------------------------
# Part 1 layout: synthetic square
# ---------------------------------------------------------------------------

# A square of the given land area (m^2) with K neighborhoods formed as the
# Voronoi cells of K random centers, so that neighborhoods differ in size as
# real subzones do. Households are uniform over the square; schools, venues
# and workplaces are uniform at random, in the same numbers as in Part 2.
square_layout <- function(area_m2, K, n_sites, n_venue_sites, margin = 1) {
  side <- sqrt(area_m2)
  cx <- runif(K, 0, side); cy <- runif(K, 0, side)
  unif <- function(m) tibble(x = runif(m, margin, side - margin), y = runif(m, margin, side - margin))
  sites <- bind_rows(lapply(names(n_sites), function(t) unif(n_sites[[t]]) |> mutate(type = t, .before = 1)))
  list(
    name = "square",
    side = side,
    neighborhoods = paste("Neighborhood", seq_len(K)),
    centers = tibble(x = cx, y = cy),
    place_households = function(hh, people) {
      p <- unif(nrow(hh))
      hh$x <- p$x; hh$y <- p$y
      hh$neighborhood <- nearest_site(hh$x, hh$y, cx, cy)
      hh
    },
    sites = sites,
    workplace_points = function(m) unif(m),
    venue_sites = unif(n_venue_sites),
    boundary = NULL
  )
}
