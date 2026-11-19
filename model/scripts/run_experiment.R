# Main experiment. One chunk = one scenario and
# calibrated set on one synthetic population, with all paired epidemics.
# Resumable: finished chunks are skipped.
# Usage: Rscript scripts/run_experiment.R n_pop n_epi
source("scripts/common.R"); source("scripts/scenarios.R")
args <- commandArgs(trailingOnly = TRUE)
n_pop <- as.integer(args[1]); n_epi <- as.integer(args[2])
prem <- load_prem_sgp()
sets <- retained_sets(); design <- experiment_design()
chunks <- merge(design, data.frame(pop = seq_len(n_pop)))
# Optional filter (A4_EXP_SCEN, comma-separated scenarios) to split a batch across servers.
f <- Sys.getenv("A4_EXP_SCEN"); if (nzchar(f)) chunks <- chunks[chunks$scenario %in% strsplit(f, ",")[[1]], ]
dir <- out_dir("experiment")
chunk_file <- function(k) file.path(dir, sprintf("%s__%s__pop%03d.rds", chunks$scenario[k], chunks$set[k], chunks$pop[k]))
todo <- Filter(function(k) !file.exists(chunk_file(k)), seq_len(nrow(chunks)))
cat(length(todo), "of", nrow(chunks), "chunks to run on", n_cores(), "cores\n")
res <- mclapply(todo, function(k) {
  sc <- chunks$scenario[k]; st <- sets[sets$set == chunks$set[k], ]; p <- chunks$pop[k]
  world <- scenario_world(readRDS(file.path(out_dir("worlds"), sprintf("world_%03d.rds", p))), sc)
  mp <- scenario_params(sc, st)
  rates <- contact_rates(world, prem); strata <- older_strata(world)
  out <- lapply(seq_len(n_epi), function(e) {
    # The same epidemic seeds are used in every scenario and set, so scenario
    # comparisons are also matched.
    r <- run_task(world, rates, mp, epi_seed = 2e6L + 1000L * p + e, strata = strata)
    keep_daily <- sc == "reference" && e <= 10L
    list(summary = r$summary, strata = r$strata, daily = if (keep_daily) r$daily else NULL)
  })
  tag <- function(df) dplyr::mutate(df, scenario = sc, set = st$set, level = st$level, pop = p)
  obj <- list(summary = tag(dplyr::bind_rows(lapply(out, `[[`, "summary"))),
              strata = tag(dplyr::bind_rows(lapply(out, `[[`, "strata"))),
              daily = { d <- dplyr::bind_rows(lapply(out, `[[`, "daily")); if (nrow(d)) tag(d) else NULL })
  save_atomic(obj, chunk_file(k))
  TRUE
}, mc.cores = n_cores(), mc.preschedule = FALSE)
bad <- vapply(res, function(x) inherits(x, "try-error"), logical(1))
if (any(bad)) stop(sum(bad), " chunks failed; first error: ", as.character(res[bad][[1]]))
cat("all chunks complete\n")
