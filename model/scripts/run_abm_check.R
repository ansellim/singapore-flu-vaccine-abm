# Run the course verification harness abm_check() on the submitted model and
# save its printed output for the report (assignment requirement).
# Usage: Rscript scripts/run_abm_check.R <path to SPH5105_Session10_setup.R> <world rds> <tau> <h>
source("scripts/common.R")
source("R/abm_check_adapter.R")
args <- commandArgs(trailingOnly = TRUE)
env <- new.env(); sys.source(args[1], envir = env)
world <- readRDS(args[2])
mp <- default_model_params(); mp$tau <- as.numeric(args[3]); mp$h <- as.numeric(args[4])
rates <- contact_rates(world, load_prem_sgp())
run_fun <- make_abm_check_run_fun(world, rates, mp, arm = "C")
also <- list(
  `broad adult allocation (Arm B)` = make_abm_check_run_fun(world, rates, mp, arm = "B"),
  `existing vaccination only (Arm A)` = make_abm_check_run_fun(world, rates, mp, arm = "A"),
  `open boundary` = { m2 <- mp; m2$ext_open_hazard <- 1e-4; make_abm_check_run_fun(world, rates, m2, arm = "C") })
pars <- env$abm_pars(n = nrow(world$people), box = world$settings_params$box)
out_file <- file.path(out_dir("summary"), "abm_check_output.txt")
txt <- capture.output(res <- env$abm_check(run_fun, pars, t_max = 310, also = also, verbose = TRUE))
writeLines(c(sprintf("abm_check() on world %d (Arm C unless stated), tau = %s, h = %s, t_max = 310 half-day steps",
                     world$pop_seed, args[3], args[4]), txt), out_file)
cat(txt, sep = "\n")
if (!all(res$pass)) quit(status = 1)
