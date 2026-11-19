# Calibration grid on Arm A (existing vaccination only).
# Usage: Rscript scripts/calibrate.R n_worlds n_epi [open]
# With "open", the grid is recalibrated with continued external exposure of
# 0.0001 per susceptible-day after day 39 (open-boundary calibration, added
# after the second review) over lower transmission scales, and the outputs
# carry the suffix "_open".
source("scripts/common.R")
args <- commandArgs(trailingOnly = TRUE)
n_worlds <- as.integer(args[1]); n_epi <- as.integer(args[2])
open_boundary <- length(args) >= 3 && args[3] == "open"
suffix <- if (open_boundary) "_open" else ""
prem <- load_prem_sgp()
grid <- expand.grid(tau = if (open_boundary) seq(0.10, 0.28, by = 0.02) else seq(0.20, 0.40, by = 0.02),
                    h = c(1, 1.5, 2, 2.5, 3))
worlds <- lapply(seq_len(n_worlds), function(s) readRDS(file.path(out_dir("worlds"), sprintf("world_%03d.rds", s))))
tasks <- expand.grid(g = seq_len(nrow(grid)), w = seq_len(n_worlds))
res <- mclapply(seq_len(nrow(tasks)), function(k) {
  g <- tasks$g[k]; wi <- tasks$w[k]; world <- worlds[[wi]]
  mp <- default_model_params(); mp$tau <- grid$tau[g]; mp$h <- grid$h[g]
  if (open_boundary) mp$ext_open_hazard <- 1e-4
  rates <- contact_rates(world, prem); strata <- older_strata(world)
  W <- prepare_world(world, rates, mp)
  dplyr::bind_rows(lapply(seq_len(n_epi), function(e) {
    S <- draw_streams(W$n, 2L * mp$n_days, ceiling(mp$n_days / 7) + 1L, 500000L + 1000L * wi + e)
    r <- simulate_arm(W, S, mp, "A")
    arm_outcomes(r, W, world, strata, mp) |> dplyr::mutate(tau = mp$tau, h = mp$h, world = wi, epi = e)
  }))
}, mc.cores = n_cores(), mc.preschedule = FALSE)
bad <- vapply(res, inherits, logical(1), "try-error")
if (any(bad)) stop("calibration failed: ", as.character(res[bad][[1]]))
out <- dplyr::bind_rows(res)
readr::write_csv(out, file.path(out_dir("summary"), paste0("calibration_runs", suffix, ".csv")))
summ <- out |> dplyr::group_by(tau, h) |>
  dplyr::summarise(ap_adult = mean(ap_adult_21_75_unvax), ap_older = mean(ap_older),
                   gi = mean(gi_mean, na.rm = TRUE), si = mean(si_mean, na.rm = TRUE),
                   si_home = mean(si_home_mean, na.rm = TRUE), share_home = mean(share_home, na.rm = TRUE),
                   n = dplyr::n(), .groups = "drop")
readr::write_csv(summ, file.path(out_dir("summary"), paste0("calibration_grid", suffix, ".csv")))
print(as.data.frame(summ))
