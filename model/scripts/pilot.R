# Pilot: variance components of the paired contrast,
# required numbers of populations, matched-randomness efficiency, and the
# outbreak-size distribution used to set the major-outbreak threshold.
# Usage: Rscript scripts/pilot.R n_pop n_epi
source("scripts/common.R"); source("scripts/scenarios.R")
args <- commandArgs(trailingOnly = TRUE)
n_pop <- as.integer(args[1]); n_epi <- as.integer(args[2])
prem <- load_prem_sgp()
sets <- retained_sets(); sets <- sets[sets$level == "reference", ]
tasks <- expand.grid(si = seq_len(nrow(sets)), p = seq_len(n_pop), e = seq_len(n_epi))
res <- mclapply(seq_len(nrow(tasks)), function(k) {
  si <- tasks$si[k]; p <- tasks$p[k]; e <- tasks$e[k]
  world <- readRDS(file.path(out_dir("worlds"), sprintf("world_%03d.rds", p)))
  mp <- scenario_params("reference", sets[si, ])
  rates <- contact_rates(world, prem); strata <- older_strata(world)
  seed <- 1e6L + 1000L * p + e
  ep <- run_epidemic(world, rates, mp, seed, record_infector = FALSE)
  o <- dplyr::bind_rows(lapply(ep$runs, arm_outcomes, W = ep$W, world = world, strata = strata, mp = mp))
  # Independent randomness for Arm C (a different epidemic seed), to measure
  # what the shared random numbers buy.
  S2 <- draw_streams(ep$W$n, 2L * mp$n_days, ceiling(mp$n_days / 7) + 1L, seed + 500000L)
  oc <- arm_outcomes(simulate_arm(ep$W, S2, mp, "C", record_infector = FALSE), ep$W, world, strata, mp)
  dplyr::bind_rows(o, oc |> dplyr::mutate(arm = "C_indep")) |>
    dplyr::mutate(set = sets$set[si], pop = p, epi = e)
}, mc.cores = n_cores(), mc.preschedule = FALSE)
bad <- vapply(res, inherits, logical(1), "try-error")
if (any(bad)) stop("pilot failed: ", as.character(res[bad][[1]]))
out <- dplyr::bind_rows(res)
readr::write_csv(out, file.path(out_dir("summary"), "pilot_runs.csv"))

wide <- out |> dplyr::select(set, pop, epi, arm, ap_older, ap_residents) |>
  tidyr::pivot_wider(names_from = arm, values_from = c(ap_older, ap_residents))
vc <- wide |> dplyr::mutate(d = ap_older_C - ap_older_B, d_ind = ap_older_C_indep - ap_older_B) |>
  dplyr::group_by(set) |>
  dplyr::group_modify(function(x, key) {
    J <- n_epi
    pm <- x |> dplyr::group_by(pop) |> dplyr::summarise(m = mean(d), v = var(d), .groups = "drop")
    sw2 <- mean(pm$v); sb2 <- max(var(pm$m) - sw2 / J, 0)
    need <- function(J2) ceiling((sb2 + sw2 / J2) / 0.005^2)
    tibble::tibble(mean_contrast = mean(x$d), sd_within = sqrt(sw2), sd_between = sqrt(sb2),
                   mcse_pilot = sd(pm$m) / sqrt(nrow(pm)),
                   var_paired = var(x$d), var_independent = var(x$d_ind),
                   variance_reduction = 1 - var(x$d) / var(x$d_ind),
                   pops_needed_J20 = need(20), pops_needed_J50 = need(50))
  }) |> dplyr::ungroup()
readr::write_csv(vc, file.path(out_dir("summary"), "pilot_variance_components.csv"))
print(as.data.frame(vc), digits = 3)
cat("\nArm A resident attack proportion quantiles:\n")
print(quantile(out$ap_residents[out$arm == "A"], c(0, .01, .05, .1, .25, .5, .75, .9, 1)))
