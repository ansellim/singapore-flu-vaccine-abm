run_arms <- function(mp, seed = 3L, world = fixture_world()$world) {
  rates <- contact_rates(world, fixture_world()$prem)
  W <- prepare_world(world, rates, mp)
  S <- draw_streams(W$n, 2L * mp$n_days, ceiling(mp$n_days / 7) + 1L, seed)
  list(W = W, S = S, runs = lapply(c(A = "A", B = "B", C = "C"), function(a) simulate_arm(W, S, mp, a)))
}

test_that("S + I + R = N at every step, R never falls and S never rises", {
  r <- run_arms(calibrated_params())
  for (run in r$runs) {
    cnt <- run$counts
    expect_true(all(rowSums(cnt[, c("S", "I", "R")]) == r$W$n))
    expect_true(all(diff(cnt[, "R"]) >= 0))
    expect_true(all(diff(cnt[, "S"]) <= 0))
  }
})

test_that("runs are reproducible from the seed and change with it", {
  mp <- calibrated_params()
  a <- run_arms(mp, 5L)$runs$A; b <- run_arms(mp, 5L)$runs$A; c2 <- run_arms(mp, 6L)$runs$A
  expect_identical(a$counts, b$counts)
  expect_false(identical(a$counts, c2$counts))
})

test_that("no individual transmits in the step in which it was infected", {
  r <- run_arms(calibrated_params())$runs$A
  has <- !is.na(r$infector)
  expect_gt(sum(has), 50)
  lag_steps <- r$inf_step[has] - r$inf_step[r$infector[has]]
  expect_true(all(lag_steps >= default_model_params()$latent_steps + 1L))
})

test_that("without transmission or introductions nobody is infected", {
  mp <- calibrated_params(); mp$tau <- 0; mp$h <- 0; mp$ext_hazard <- 0
  r <- run_arms(mp)$runs$A
  expect_true(all(is.na(r$inf_step)))
})

test_that("without local transmission every infection is external", {
  mp <- calibrated_params(); mp$tau <- 0
  r <- run_arms(mp)$runs$A
  inf <- !is.na(r$inf_step)
  expect_gt(sum(inf), 0)
  expect_true(all(r$setting[inf] == 6L))
  day <- (r$inf_step[inf] - 1L) %/% 2L
  expect_true(all(day >= mp$ext_start_day & day <= mp$ext_end_day))
})

test_that("both campaigns administer the same number of doses and Arm C prioritizes older adults", {
  r <- run_arms(calibrated_params())
  B <- r$runs$B; C <- r$runs$C; pp <- r$W$pp
  expect_equal(B$budget, C$budget)
  expect_equal(sum(!is.na(B$dose_day)), sum(!is.na(C$dose_day)))
  older_elig <- sum(pp$resident & pp$age >= 65 & !C$base_vax)
  expect_equal(sum(!is.na(C$dose_day) & pp$age >= 65), min(C$budget, older_elig))
  expect_false(any(!is.na(C$dose_day) & (pp$fdw | pp$age < 18)))
  expect_true(all(C$dose_day[!is.na(C$dose_day)] %in% 7:20))
  expect_equal(r$runs$A$budget, 0)
})

test_that("the older-adult uptake cap limits coverage of residents aged 65+ and passes doses on", {
  mp <- calibrated_params(); mp$older_uptake_cap <- 0.75
  r <- run_arms(mp); pp <- r$W$pp
  older <- pp$resident & pp$age >= 65
  for (a in c("B", "C")) {
    run <- r$runs[[a]]
    covered <- sum(older & (run$base_vax | !is.na(run$dose_day)))
    expect_lte(covered, floor(0.75 * sum(older)))
  }
  # Arm C fills the capped older pool exactly, then gives its remaining doses
  # to younger adults, so both arms still give the same number of doses.
  C <- r$runs$C
  expect_equal(sum(older & (C$base_vax | !is.na(C$dose_day))), floor(0.75 * sum(older)))
  expect_equal(sum(!is.na(C$dose_day)), sum(!is.na(r$runs$B$dose_day)))
  expect_gt(sum(!is.na(C$dose_day) & pp$age < 65), 0)
  # Without the cap, Arm C covers more older adults than with it.
  C1 <- run_arms(calibrated_params())$runs$C
  expect_gt(sum(older & !is.na(C1$dose_day)), sum(older & !is.na(C$dose_day)))
})

test_that("with zero vaccine protection the two campaigns give identical epidemics", {
  mp <- calibrated_params(); mp$ve_adult <- 0; mp$ve_older <- 0; mp$ve_child <- 0
  r <- run_arms(mp)
  expect_identical(r$runs$B$inf_step, r$runs$C$inf_step)
  expect_identical(r$runs$A$inf_step, r$runs$C$inf_step)
})

test_that("with gamma = 0, reassigning floor area changes nothing", {
  mp <- calibrated_params()
  w <- fixture_world()$world
  w2 <- w; set.seed(1); w2$households$area_per_occupant <- sample(w2$households$area_per_occupant)
  a <- run_arms(mp, 4L, w)$runs$A; b <- run_arms(mp, 4L, w2)$runs$A
  expect_identical(a$inf_step, b$inf_step)
  mp$gamma <- 0.5
  a <- run_arms(mp, 4L, w)$runs$A; b <- run_arms(mp, 4L, w2)$runs$A
  expect_false(identical(a$inf_step, b$inf_step))
})

test_that("living-space multipliers are bounded and average one over contact opportunities", {
  mp <- calibrated_params(); mp$gamma <- 0.5
  w <- fixture_world()$world
  W <- prepare_world(w, contact_rates(w, fixture_world()$prem), mp)
  hh <- w$households
  m <- W$hh_pair_scale[match(hh$hh_id, W$pp$hh_id)] / (mp$h / pmax(hh$occupants - 1, 1)^mp$delta)
  pairs <- hh$occupants * (hh$occupants - 1)
  expect_equal(sum(m * pairs) / sum(pairs), 1, tolerance = 1e-8)
})

test_that("generated infectiousness profile has the specified generation interval", {
  mp <- default_model_params(); w <- infectiousness_profile(mp)
  t_mid <- (seq_along(w) - 0.5) * mp$dt
  expect_equal(sum(w) * mp$dt, 1, tolerance = 1e-12)
  expect_true(all(w[seq_len(mp$latent_steps)] == 0))
  expect_equal(sum(w * t_mid) * mp$dt, mp$gi_mean, tolerance = 0.15)
})

test_that("domestic workers are excluded from resident outcomes", {
  mp <- calibrated_params(); world <- fixture_world()$world
  ep <- run_epidemic(world, contact_rates(world, fixture_world()$prem), mp, 9L)
  o <- arm_outcomes(ep$runs$A, ep$W, world, older_strata(world), mp)
  pp <- ep$W$pp; inf <- !is.na(ep$runs$A$inf_step)
  expect_equal(o$ap_residents, mean(inf[pp$resident]))
  expect_equal(o$infections_residents, sum(inf[pp$resident]))
})

test_that("a longer run shares the random numbers of the standard run and reproduces it up to day 155", {
  mp <- calibrated_params(); mp$ext_open_hazard <- 1e-4
  short <- run_arms(mp, 7L)
  mp_long <- mp; mp_long$n_days <- 215L; mp_long$ext_open_end_day <- 155L
  long <- run_arms(mp_long, 7L)
  for (nm in c("u_prior", "u_vax", "u_order", "u_symp", "u_home", "u_setting", "u_infector"))
    expect_identical(short$S[[nm]], long$S[[nm]])
  expect_identical(short$S$U_inf, long$S$U_inf[, seq_len(ncol(short$S$U_inf))])
  expect_identical(short$S$U_rest, long$S$U_rest[, seq_len(ncol(short$S$U_rest))])
  for (a in c("A", "B", "C")) {
    s <- short$runs[[a]]; l <- long$runs[[a]]
    expect_identical(s$counts, l$counts[seq_len(nrow(s$counts)), ])
    # No external infection after day 155 in the long run.
    ext_days <- (l$inf_step[which(l$setting == 6L)] - 1L) %/% 2L
    expect_true(all(ext_days <= 155L))
  }
})
