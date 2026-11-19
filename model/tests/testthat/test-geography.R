# Full-scale geographies (Parts 1 and 2), tested on a population synthesized
# from the stored Census inputs at the Queenstown age-sex and household-size
# margins, scaled to 6,000 residents to keep the suite fast.

ext_fixture <- local({
  cache <- NULL
  function() {
    if (is.null(cache)) {
      qt <- queenstown_inputs()
      inp <- load_inputs(); inp$age_sex <- read_age_sex("Queenstown - Total")
      pp <- default_population_params(); pp$target_residents <- 6000
      pp$size_households <- qt$hh_size |> dplyr::mutate(households = households * 6000 / sum(inp$age_sex$count))
      pop <- synthesize_population(inp, 11L, pp)
      set.seed(12, kind = "L'Ecuyer-CMRG"); sq <- assign_settings_layout(pop, inp, square_layout_for(qt))
      set.seed(13, kind = "L'Ecuyer-CMRG"); qw <- assign_settings_layout(pop, inp, queenstown_layout(qt))
      cache <<- list(qt = qt, inp = inp, pop = pop, square = sq, queenstown = qw)
    }
    cache
  }
})

# Ray-casting point-in-polygon test against the stored outline (no sf on the
# servers): a point is inside if it is inside an odd number of rings.
in_outline <- function(x, y, outline) {
  inside <- logical(length(x))
  for (pt in unique(outline$part)) {
    r <- outline[outline$part == pt, ]
    n <- nrow(r); j <- c(n, seq_len(n - 1))
    for (i in seq_len(n)) {
      xi <- r$x[i]; yi <- r$y[i]; xj <- r$x[j[i]]; yj <- r$y[j[i]]
      cross <- ((yi > y) != (yj > y)) & (x < (xj - xi) * (y - yi) / (yj - yi + 1e-12) + xi)
      inside <- xor(inside, cross)
    }
  }
  inside
}

test_that("the synthesized population follows the Queenstown margins", {
  f <- ext_fixture()
  expect_true(f$pop$accepted)
  hh <- f$pop$households
  expect_equal(nrow(hh), round(sum(f$qt$hh_size$households) * 6000 / sum(f$inp$age_sex$count)), tolerance = 0.01)
  # Queenstown households are smaller than the national average (2.59 vs 3.06 residents).
  expect_lt(mean(hh$residents), 2.8)
  older <- mean(f$pop$people$age[f$pop$people$resident] >= 65)
  expect_equal(older, sum(f$inp$age_sex$count[f$inp$age_sex$age_lo >= 65]) / sum(f$inp$age_sex$count), tolerance = 0.02)
})

test_that("both layouts hold the same people and differ only in where they are", {
  f <- ext_fixture()
  a <- f$square$people; b <- f$queenstown$people
  expect_identical(a[, c("person_id", "hh_id", "age", "sex", "fdw")], b[, c("person_id", "hh_id", "age", "sex", "fdw")])
  expect_false(isTRUE(all.equal(a$home_x, b$home_x)))
  # Same numbers of school, tertiary and venue sites in both parts.
  expect_identical(table(f$square$sites$type), table(f$queenstown$sites$type))
  expect_equal(nrow(f$square$venue_sites), nrow(f$queenstown$venue_sites))
})

test_that("Part 1 homes and destinations lie inside the square, with one neighborhood per populated subzone", {
  sq <- ext_fixture()$square; side <- sqrt(ext_fixture()$qt$area_m2)
  for (d in list(sq$households, sq$sites, sq$workplaces, sq$venue_sites))
    expect_true(all(d$x > 0 & d$x < side & d$y > 0 & d$y < side))
  expect_setequal(unique(sq$households$neighborhood), seq_len(sum(ext_fixture()$qt$subzones$residents > 0)))
})

test_that("Part 2 homes are at real addresses inside Queenstown, matching their subzone and dwelling type", {
  f <- ext_fixture(); hh <- f$queenstown$households
  pa <- f$qt$outline[f$qt$outline$level == "planning_area", ]
  expect_true(mean(in_outline(hh$x, hh$y, pa)) > 0.99)
  # Every household lies inside its own subzone (allowing for the 15 m spread around blocks).
  sz <- f$qt$outline[f$qt$outline$level == "subzone", ]
  own <- vapply(seq_len(nrow(hh)), function(i) in_outline(hh$x[i], hh$y[i], sz[sz$id == hh$subzone[i], ]), logical(1))
  expect_gt(mean(own), 0.97)
  # HDB households live in a block of their subzone; flat type determines floor area.
  hdb <- hh[startsWith(hh$dwelling, "hdb"), ]
  bl <- f$qt$blocks[match(hdb$block_id, f$qt$blocks$block_id), ]
  expect_true(all(!is.na(bl$block_id)))
  expect_gt(mean(bl$subzone == hdb$subzone), 0.98)
  four <- hh$floor_area[hh$dwelling == "hdb_4room"]
  expect_true(all(four >= 85 & four <= 105))
  # Dwelling-type shares of households follow the Census within 3 points.
  obs <- prop.table(table(factor(hh$dwelling, levels = dwelling_types)))
  tgt <- f$qt$dwell_households$households[match(dwelling_types, f$qt$dwell_households$dwelling)]
  expect_lt(max(abs(obs - tgt / sum(tgt))), 0.03)
  expect_true(all(attr(hh, "cell_fit") < 0.10))
})

test_that("settings follow the shared rules in both parts", {
  for (w in list(ext_fixture()$square, ext_fixture()$queenstown)) {
    pp <- w$people
    # Students all have a class at a site of their level; workers a workplace.
    st <- !is.na(pp$level)
    expect_true(all(!is.na(pp$class_id[st])))
    expect_true(all(w$sites$type[match(pp$school_site[st], w$sites$site_id)] == pp$level[st]))
    expect_true(all(!is.na(pp$workplace_id[pp$worker])))
    expect_false(any(pp$worker & (pp$fdw | pp$age < 15)))
    # Venue groups average about 125 members; gathering groups about 250.
    expect_equal(mean(table(pp$venue_id)), 125, tolerance = 0.25)
    expect_true(all(is.na(pp$gathering_id[!pp$fdw])) && all(!is.na(pp$gathering_id[pp$fdw])))
    # Primary pupils attend their nearest primary site.
    pr <- which(pp$level == "primary")
    s <- w$sites[w$sites$type == "primary", ]
    d <- outer(pp$home_x[pr], s$x, "-")^2 + outer(pp$home_y[pr], s$y, "-")^2
    expect_identical(s$site_id[max.col(-d, ties.method = "first")], pp$school_site[pr])
  }
})

test_that("epidemics run on both layouts with conservation and gathering groups", {
  for (w in list(ext_fixture()$square, ext_fixture()$queenstown)) {
    mp <- calibrated_params(); mp$ext_open_hazard <- 1e-4
    rates <- contact_rates(w, load_prem_sgp())
    W <- prepare_world(w, rates, mp)
    expect_gt(W$n_gatherings, 0L)
    S <- draw_streams(W$n, 2L * mp$n_days, ceiling(mp$n_days / 7) + 1L, 5L)
    run <- simulate_arm(W, S, mp, "A")
    expect_true(all(rowSums(run$counts[, c("S", "I", "R")]) == W$n))
    expect_gt(sum(!is.na(run$inf_step)), 0)
    # Every attributed infector shares the setting with the case.
    has <- which(!is.na(run$infector) & run$setting == 5L)
    expect_true(all(W$gather_index[has] == W$gather_index[run$infector[has]]))
  }
})

test_that("neighborhood outcomes count residents and older residents correctly", {
  w <- ext_fixture()$queenstown
  mp <- calibrated_params(); mp$ext_open_hazard <- 1e-4
  W <- prepare_world(w, contact_rates(w, load_prem_sgp()), mp)
  S <- draw_streams(W$n, 2L * mp$n_days, ceiling(mp$n_days / 7) + 1L, 9L)
  run <- simulate_arm(W, S, mp, "A")
  nb <- neighborhood_outcomes(run, W)
  pp <- W$pp; inf <- !is.na(run$inf_step); old <- pp$resident & pp$age >= 65
  expect_true(all(nb$older_infected <= nb$older))
  expect_equal(sum(nb$older_infected), sum(inf & old))
  expect_equal(sum(nb$infected), sum(inf & pp$resident))
  expect_equal(sum(nb$older), sum(old))
})

test_that("the corrected Queenstown inputs place the university and venues inside the planning area", {
  old <- Sys.getenv("A4_QT_MODEL_DIR"); on.exit(Sys.setenv(A4_QT_MODEL_DIR = old))
  Sys.setenv(A4_QT_MODEL_DIR = "model")
  qt <- queenstown_inputs()
  ter <- qt$sites[qt$sites$type == "tertiary", ]
  expect_setequal(ter$name, c("ANGLO-CHINESE JUNIOR COLLEGE", "National University of Singapore", "Singapore Polytechnic"))
  # The university site lies inside the Kent Ridge or National University subzone.
  nus <- ter[ter$name == "National University of Singapore", ]
  sz <- qt$outline[qt$outline$level == "subzone", ]
  inside <- vapply(c("Kent Ridge", "National University Of S'pore"),
                   function(z) in_outline(nus$x, nus$y, sz[tolower(sz$id) == tolower(z), ]), logical(1))
  expect_true(any(inside))
  # Supermarkets are inside the planning area; hawker centers and clubs within 300 m.
  pa <- qt$outline[qt$outline$level == "planning_area", ]
  sm <- qt$venues[qt$venues$kind == "supermarket", ]
  expect_gt(nrow(sm), 0)
  expect_true(all(in_outline(sm$x, sm$y, pa)))
  expect_equal(sum(qt$venues$kind == "hawker centre"), 10)
})
