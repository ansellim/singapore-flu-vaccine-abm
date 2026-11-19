# Full-scale experiment of Parts 1 (square) and 2 (Queenstown). One chunk =
# one geography, scenario and parameter set on one population, with all its
# paired epidemics. Epidemic seeds match across geographies, scenarios and
# sets, so every comparison is paired. Resumable.
# Usage: Rscript scripts/run_extension.R pop_from pop_to n_epi
source("scripts/common.R"); source("scripts/scenarios.R")
args <- commandArgs(trailingOnly = TRUE)
pops <- as.integer(args[1]):as.integer(args[2]); n_epi <- as.integer(args[3])
prem <- load_prem_sgp(); sets <- retained_sets()
design <- extension_design()
chunks <- merge(design, data.frame(pop = pops))
# Optional filters (used to finish the design within the compute deadline):
# A4_EXT_SCEN (comma-separated scenarios), A4_EXT_SETS (comma-separated sets).
for (v in c("A4_EXT_SCEN", "A4_EXT_SETS")) {
  f <- Sys.getenv(v); col <- if (v == "A4_EXT_SCEN") "scenario" else "set"
  if (nzchar(f)) chunks <- chunks[chunks[[col]] %in% strsplit(f, ",")[[1]], ]
}
# Longest chunks (open boundary) first, interleaving geographies.
chunks <- chunks[order(-grepl("open", chunks$scenario), chunks$pop, chunks$geography), ]
dir <- out_dir(Sys.getenv("A4_EXT_DIR", unset = "experiment_ext"))
chunk_file <- function(k) file.path(dir, sprintf("%s__%s__%s__pop%03d.rds", chunks$geography[k], chunks$scenario[k],
                                                 chunks$set[k], chunks$pop[k]))
todo <- Filter(function(k) !file.exists(chunk_file(k)), seq_len(nrow(chunks)))
cat(length(todo), "of", nrow(chunks), "chunks to run on", n_cores(), "cores\n")
res <- mclapply(todo, function(k) {
  g <- chunks$geography[k]; sc <- chunks$scenario[k]; st <- sets[sets$set == chunks$set[k], ]; p <- chunks$pop[k]
  world <- scenario_world(readRDS(file.path(out_dir(paste0("worlds_", g)), sprintf("world_%03d.rds", p))), sc)
  mp <- scenario_params(sc, st)
  rates <- contact_rates(world, prem); strata <- older_strata(world)
  out <- lapply(seq_len(n_epi), function(e) {
    r <- run_task(world, rates, mp, epi_seed = 3e6L + 1000L * p + e, strata = strata)
    keep_daily <- sc %in% c("reference", "open_boundary") && e <= 10L
    list(summary = r$summary, strata = r$strata, neighborhood = r$neighborhood,
         daily = if (keep_daily) r$daily else NULL)
  })
  tag <- function(df) dplyr::mutate(df, geography = g, scenario = sc, set = st$set, level = st$level, pop = p)
  obj <- list(summary = tag(dplyr::bind_rows(lapply(out, `[[`, "summary"))),
              strata = tag(dplyr::bind_rows(lapply(out, `[[`, "strata"))),
              neighborhood = tag(dplyr::bind_rows(lapply(out, `[[`, "neighborhood"))),
              daily = { d <- dplyr::bind_rows(lapply(out, `[[`, "daily")); if (nrow(d)) tag(d) else NULL })
  save_atomic(obj, chunk_file(k))
  TRUE
}, mc.cores = n_cores(), mc.preschedule = FALSE)
bad <- vapply(res, function(x) inherits(x, "try-error"), logical(1))
if (any(bad)) stop(sum(bad), " chunks failed; first error: ", as.character(res[bad][[1]]))
cat("all chunks complete\n")
