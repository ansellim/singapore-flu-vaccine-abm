# Shared setup for command-line scripts. Run from the model/ directory.
# On the servers, A4_RLIB points to the project R library.
lib <- Sys.getenv("A4_RLIB", unset = "")
if (nzchar(lib)) .libPaths(c(lib, .libPaths()))
for (f in c("data_inputs", "population", "settings", "geography", "queenstown", "model", "experiment"))
  source(file.path("R", paste0(f, ".R")))
suppressPackageStartupMessages(library(parallel))
out_dir <- function(...) {
  d <- file.path(Sys.getenv("A4_OUT", unset = "../outputs"), ...)
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
  d
}
n_cores <- function() as.integer(Sys.getenv("A4_CORES", unset = "4"))
# Write atomically so an interrupted batch never leaves a partial file.
save_atomic <- function(obj, path) {
  tmp <- paste0(path, ".tmp")
  saveRDS(obj, tmp)
  if (!file.rename(tmp, path)) stop("could not move ", tmp, " to ", path)
}
