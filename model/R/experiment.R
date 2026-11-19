# Worlds, paired epidemics and outcomes.

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
})

setting_labels <- c("home", "school", "work", "community", "gathering", "external")

# A world is one accepted synthetic population with its settings. Populations
# that fail the fit threshold are rejected and redrawn with the next seed; the
# number of rejections is recorded.
build_world <- function(pop_seed, inputs, pp = default_population_params(),
                        sp = default_settings_params(), max_tries = 5L) {
  tries <- 0L; seed <- pop_seed
  repeat {
    tries <- tries + 1L
    pop <- synthesize_population(inputs, seed, pp)
    if (pop$accepted) break
    if (tries >= max_tries) stop("no accepted population after ", max_tries, " tries from seed ", pop_seed)
    seed <- seed + 100000L
  }
  set.seed(seed + 1L, kind = "L'Ecuyer-CMRG")
  world <- assign_settings(pop, inputs, sp)
  world$fit <- pop$fit; world$fit_cells <- pop$fit_cells
  world$pop_seed <- pop_seed; world$accepted_seed <- seed; world$rejections <- tries - 1L
  world
}

# Older-adult household strata at baseline.
older_strata <- function(world) {
  pp <- world$people; hh <- world$households
  kids <- pp |> group_by(hh_id) |> summarise(has_under18 = any(age < 18 & resident), .groups = "drop")
  pp |>
    filter(resident, age >= 65) |>
    left_join(hh |> select(hh_id, occupants, has_fdw, area_per_occupant), by = "hh_id") |>
    left_join(kids, by = "hh_id") |>
    transmute(person_id, age,
              arrangement = case_when(
                older_arrangement == "alone" ~ "alone",
                older_arrangement == "spouse_no_child" ~ "spouse_only",
                older_arrangement %in% c("spouse_child", "child_no_spouse") ~ "with_own_children",
                TRUE ~ "other"),
              has_fdw, has_under18, occupants,
              area_tertile = cut(area_per_occupant,
                                 quantile(world$households$area_per_occupant, c(0, 1/3, 2/3, 1)),
                                 include.lowest = TRUE, labels = c("low", "mid", "high")))
}

run_epidemic <- function(world, rates, mp, epi_seed, arms = c("A", "B", "C"), record_infector = TRUE) {
  W <- prepare_world(world, rates, mp)
  S <- draw_streams(W$n, 2L * mp$n_days, ceiling(mp$n_days / 7) + 1L, epi_seed)
  out <- lapply(arms, function(a) simulate_arm(W, S, mp, a, record_infector))
  names(out) <- arms
  list(runs = out, W = W, epi_seed = epi_seed)
}

# Outcomes for one arm run.
arm_outcomes <- function(run, W, world, strata, mp) {
  pp <- W$pp
  infected <- !is.na(run$inf_step)
  res <- pp$resident
  older <- res & pp$age >= 65
  onward <- infected & run$setting != 6L
  adult_cal <- res & pp$age >= 21 & pp$age <= 75 & !run$base_vax
  cnt <- run$counts
  peak_step <- if (max(cnt[, "infectious"]) > 0) which.max(cnt[, "infectious"]) - 1L else NA_integer_
  # Generation and serial intervals among cases with a recorded infector.
  gi <- (run$inf_step - run$inf_step[run$infector]) * mp$dt
  si_ok <- !is.na(run$infector) & run$symptomatic & run$symptomatic[pmax(run$infector, 1L)]
  # Spatial measures.
  nb <- pp$neighborhood
  first_day <- tapply(ifelse(infected, run$inf_step * mp$dt, NA), nb, function(x) suppressWarnings(min(x, na.rm = TRUE)))
  first_day[!is.finite(first_day)] <- NA
  cross_nb <- sum(!is.na(run$infector) & nb[pmax(run$infector, 1L)] != nb & !is.na(run$infector))
  hh_onward <- tapply(onward & run$setting == 1L, pp$hh_id, any)
  tibble(
    arm = run$arm,
    ap_older = mean(infected[older]),
    ap_older_onward = mean(onward[older]),
    ap_residents = mean(infected[res]),
    ap_adult_21_75_unvax = mean(infected[adult_cal]),
    ap_fdw = if (any(pp$fdw)) mean(infected[pp$fdw]) else NA_real_,
    infections_residents = sum(infected[res]),
    infections_older = sum(infected[older]),
    peak_infectious = max(cnt[, "infectious"]),
    peak_day = if (is.na(peak_step)) NA_real_ else peak_step * mp$dt,
    still_infected_end = cnt[nrow(cnt), "I"],
    doses = run$budget,
    doses_older = sum(!is.na(run$dose_day) & older),
    hh_with_onward = mean(hh_onward),
    neighborhoods_reached = sum(!is.na(first_day)),
    first_day_nb1 = first_day["1"], first_day_nb2 = first_day["2"],
    first_day_nb3 = first_day["3"], first_day_nb4 = first_day["4"],
    cross_neighborhood_events = cross_nb,
    gi_mean = mean(gi, na.rm = TRUE), gi_n = sum(!is.na(gi)),
    si_mean = mean(gi[si_ok], na.rm = TRUE), si_n = sum(si_ok),
    si_home_mean = mean(gi[si_ok & run$setting == 1L], na.rm = TRUE),
    share_home = mean(run$setting[onward] == 1L),
    share_school = mean(run$setting[onward] == 2L),
    share_work = mean(run$setting[onward] == 3L),
    share_community = mean(run$setting[onward] == 4L),
    share_gathering = mean(run$setting[onward] == 5L),
    n_external = sum(infected & run$setting == 6L)
  )
}

# Older-adult attack proportion by baseline household stratum, for one arm.
stratum_outcomes <- function(run, strata) {
  inf <- !is.na(run$inf_step[strata$person_id])
  s <- strata |> mutate(infected = inf)
  bind_rows(
    s |> group_by(stratum_level = arrangement) |> summarise(n = n(), ap = mean(infected), .groups = "drop") |> mutate(stratum = "arrangement"),
    s |> group_by(stratum_level = ifelse(has_fdw, "fdw", "no_fdw")) |> summarise(n = n(), ap = mean(infected), .groups = "drop") |> mutate(stratum = "domestic_worker"),
    s |> group_by(stratum_level = ifelse(has_under18, "with_under18", "no_under18")) |> summarise(n = n(), ap = mean(infected), .groups = "drop") |> mutate(stratum = "under18"),
    s |> group_by(stratum_level = as.character(pmin(occupants, 5L))) |> summarise(n = n(), ap = mean(infected), .groups = "drop") |> mutate(stratum = "occupants"),
    s |> group_by(stratum_level = as.character(area_tertile)) |> summarise(n = n(), ap = mean(infected), .groups = "drop") |> mutate(stratum = "area")
  ) |> mutate(arm = run$arm)
}

# One task: one world, one epidemic seed, all arms of one scenario.
run_task <- function(world, rates, mp, epi_seed, strata = older_strata(world), record_infector = TRUE) {
  ep <- run_epidemic(world, rates, mp, epi_seed, record_infector = record_infector)
  summ <- bind_rows(lapply(ep$runs, arm_outcomes, W = ep$W, world = world, strata = strata, mp = mp))
  strat <- bind_rows(lapply(ep$runs, stratum_outcomes, strata = strata))
  daily <- bind_rows(lapply(ep$runs, function(r) {
    c2 <- r$counts
    tibble(arm = r$arm, step = seq_len(nrow(c2)) - 1L, S = c2[, "S"], I = c2[, "I"], R = c2[, "R"],
           infectious = c2[, "infectious"], new = c2[, "new"])
  })) |> filter(step %% 2L == 0L) |> mutate(day = step %/% 2L)
  nbhd <- bind_rows(lapply(ep$runs, neighborhood_outcomes, W = ep$W))
  list(summary = summ |> mutate(epi_seed = epi_seed),
       strata = strat |> mutate(epi_seed = epi_seed),
       daily = daily |> mutate(epi_seed = epi_seed),
       neighborhood = nbhd |> mutate(epi_seed = epi_seed))
}

# Residents and older residents infected, by home neighborhood (subzone in
# Part 2), for maps of where infection and its prevention fall.
neighborhood_outcomes <- function(run, W) {
  pp <- W$pp
  inf <- !is.na(run$inf_step)
  tibble(nb = pp$neighborhood, resident = pp$resident, older = pp$resident & pp$age >= 65, inf = inf) |>
    filter(resident) |>
    group_by(neighborhood = nb) |>
    summarise(residents = n(), infected = sum(inf), older_infected = sum(older & inf), older = sum(older),
              .groups = "drop") |>
    mutate(arm = run$arm)
}
