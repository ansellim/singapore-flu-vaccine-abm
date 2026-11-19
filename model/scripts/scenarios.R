# Calibrated parameter sets retained by the prespecified acceptance ranges
# (results/summary/calibration_grid.csv) and the minimum experiment's
# scenarios. Every scenario changes one thing from the
# reference. Set H1 is not calibrated: it was added post hoc as a
# higher-transmission sensitivity
# set, a grid cell whose adult attack proportion (about 23%) lies above the
# reference acceptance range. Sets O1 to O4 were added post hoc:
# they are the reference-level combinations
# retained when the grid was recalibrated with continued external exposure
# of 0.0001 per day (results/summary/calibration_grid_open.csv), and are run
# only with that exposure.
retained_sets <- function() {
  data.frame(
    set = c("R1", "R2", "R3", "R4", "L1", "L2", "H1", "O1", "O2", "O3", "O4"),
    level = c(rep("reference", 4), rep("lower", 2), "higher", rep("open-calibrated", 4)),
    tau = c(0.24, 0.26, 0.28, 0.30, 0.20, 0.22, 0.30, 0.22, 0.24, 0.26, 0.28),
    h = c(2.5, 2.0, 1.5, 1.0, 3.0, 2.5, 1.5, 2.5, 2.0, 1.5, 1.0),
    stringsAsFactors = FALSE)
}

# Scenarios of the main experiment (prespecified) and those added post hoc,
# all run at the reference level.
main_scenarios <- c("reference", "weak_older_ve", "null_older_ve", "open_boundary",
                    "living_space", "living_space_controlled", "shuffled_geography")
added_scenarios <- c("open_boundary_2e5", "open_boundary_5e5", "open_boundary_2e4", "open_boundary_long",
                     "equal_older_ve", "weak_adult_ve", "older_cap", "older_cap_open")
# Prespecified vaccine-parameter sensitivity ranges, run after the main and added scenarios: protection in children,
# coverage at ages 75 and over, coverage in children and waning of baseline
# doses, each at the low and high end of its stated range.
sensitivity_scenarios <- c("child_ve_30", "child_ve_71", "cov75_406", "cov75_60",
                           "child_cov_4", "child_cov_15", "waning_069", "waning_none",
                           # Prespecified robustness question: probability
                           # of staying home after recognized illness, reference 0.5.
                           "stay_home_25", "stay_home_75")

scenario_params <- function(scenario, set_row) {
  mp <- default_model_params(); mp$tau <- set_row$tau; mp$h <- set_row$h
  switch(scenario,
    reference = NULL,
    weak_older_ve = { mp$ve_older <- 0.10 },
    null_older_ve = { mp$ve_older <- 0 },
    open_boundary = { mp$ext_open_hazard <- 1e-4 },
    open_boundary_2e5 = { mp$ext_open_hazard <- 2e-5 },
    open_boundary_5e5 = { mp$ext_open_hazard <- 5e-5 },
    open_boundary_2e4 = { mp$ext_open_hazard <- 2e-4 },
    # Final-size check: exposure stops after day 155 and the run continues to
    # day 215, sharing every random number of the 155-day run (draw_streams).
    open_boundary_long = { mp$ext_open_hazard <- 1e-4; mp$ext_open_end_day <- 155L; mp$n_days <- 215L },
    equal_older_ve = { mp$ve_older <- 0.40 },
    weak_adult_ve = { mp$ve_adult <- 0.20 },
    older_cap = { mp$older_uptake_cap <- 0.75 },
    older_cap_open = { mp$older_uptake_cap <- 0.75; mp$ext_open_hazard <- 1e-4 },
    child_ve_30 = { mp$ve_child <- 0.30 },
    child_ve_71 = { mp$ve_child <- 0.71 },
    cov75_406 = { mp$coverage$a75p <- 0.406 },
    cov75_60 = { mp$coverage$a75p <- 0.60 },
    child_cov_4 = { mp$coverage$child <- 0.04 },
    child_cov_15 = { mp$coverage$child <- 0.15 },
    waning_069 = { mp$waning_baseline <- 0.69 },
    waning_none = { mp$waning_baseline <- 1.0 },
    stay_home_25 = { mp$p_stay_home <- 0.25 },
    stay_home_75 = { mp$p_stay_home <- 0.75 },
    living_space = { mp$gamma <- 0.5 },
    shuffled_geography = NULL,
    living_space_controlled = { mp$gamma <- 0.5 },
    stop("unknown scenario ", scenario))
  mp
}

experiment_design <- function() {
  s <- retained_sets()
  ref <- expand.grid(set = s$set[s$level == "reference"], scenario = c(main_scenarios, added_scenarios, sensitivity_scenarios),
                     stringsAsFactors = FALSE)
  low <- data.frame(set = s$set[s$level == "lower"], scenario = "reference", stringsAsFactors = FALSE)
  high <- data.frame(set = "H1", scenario = c("reference", "open_boundary"), stringsAsFactors = FALSE)
  open_cal <- expand.grid(set = s$set[s$level == "open-calibrated"], scenario = c("open_boundary", "older_cap_open"),
                          stringsAsFactors = FALSE)
  rbind(ref, low, high, open_cal)
}

# Scenario-specific changes to the world itself (geography or floor area).
scenario_world <- function(world, scenario) {
  if (scenario == "shuffled_geography") {
    set.seed(world$pop_seed + 7770000L, kind = "L'Ecuyer-CMRG")
    return(shuffle_destinations(world))
  }
  if (scenario == "living_space_controlled") {
    # Controlled structural analysis: floor area per
    # occupant is reassigned at random within strata of household size and
    # structure, holding members and outside contacts fixed.
    set.seed(world$pop_seed + 8880000L, kind = "L'Ecuyer-CMRG")
    hh <- world$households
    for (key in unique(paste(hh$size_class, hh$structure))) {
      idx <- which(paste(hh$size_class, hh$structure) == key)
      if (length(idx) > 1) hh$area_per_occupant[idx] <- hh$area_per_occupant[idx][sample.int(length(idx))]
    }
    world$households <- hh
  }
  world
}

# Full-scale extension (Parts 1 and 2): the same design on both geographies.
extension_design <- function() {
  s <- retained_sets()
  ref <- expand.grid(set = s$set[s$level == "reference"],
                     scenario = c("reference", "open_boundary", "shuffled_geography"), stringsAsFactors = FALSE)
  open_cal <- expand.grid(set = s$set[s$level == "open-calibrated"], scenario = c("open_boundary", "older_cap_open"),
                          stringsAsFactors = FALSE)
  # Vaccine-protection scenarios at full scale, in sets R1 to R4.
  vacc <- expand.grid(set = s$set[s$level == "reference"], scenario = c("weak_older_ve", "equal_older_ve"),
                      stringsAsFactors = FALSE)
  d <- rbind(ref, open_cal, vacc)
  merge(d, data.frame(geography = c("square", "queenstown"), stringsAsFactors = FALSE))
}
