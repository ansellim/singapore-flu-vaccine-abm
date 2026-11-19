# Build accepted synthetic worlds for population seeds 1..N (resumable).
# Usage: Rscript scripts/build_worlds.R N
source("scripts/common.R")
args <- commandArgs(trailingOnly = TRUE)
N <- as.integer(args[1])
inp <- load_inputs()
dir <- out_dir("worlds")
todo <- Filter(function(s) !file.exists(file.path(dir, sprintf("world_%03d.rds", s))), seq_len(N))
cat("building", length(todo), "worlds on", n_cores(), "cores\n")
res <- mclapply(todo, function(s) {
  w <- build_world(s, inp)
  save_atomic(w, file.path(dir, sprintf("world_%03d.rds", s)))
  w$fit |> dplyr::mutate(pop_seed = s, accepted_seed = w$accepted_seed, rejections = w$rejections,
                         residents = sum(w$people$resident), fdw = sum(w$people$fdw),
                         households = nrow(w$households))
}, mc.cores = n_cores(), mc.preschedule = FALSE)
bad <- vapply(res, inherits, logical(1), "try-error")
if (any(bad)) stop("world building failed: ", paste(vapply(res[bad], as.character, ""), collapse = "\n"))
fits <- dplyr::bind_rows(lapply(list.files(dir, "^world_\\d+\\.rds$", full.names = TRUE), function(f) {
  w <- readRDS(f)
  w$fit |> dplyr::mutate(pop_seed = w$pop_seed, accepted_seed = w$accepted_seed, rejections = w$rejections,
                         residents = sum(w$people$resident), fdw = sum(w$people$fdw), households = nrow(w$households))
}))
readr::write_csv(fits, file.path(out_dir("summary"), "world_fit.csv"))
print(fits |> dplyr::group_by(table) |> dplyr::summarise(max_sae = max(sae), mean_sae = mean(sae)))
