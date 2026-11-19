# Run from the model/ directory: Rscript tests/testthat.R
lib <- Sys.getenv("A4_RLIB", unset = "")
if (nzchar(lib)) .libPaths(c(lib, .libPaths()))
library(testthat)
# test_dir() changes the working directory, so pin the assessment root first.
if (!nzchar(Sys.getenv("A4_ROOT"))) Sys.setenv(A4_ROOT = normalizePath(".."))
for (f in c("data_inputs", "population", "settings", "geography", "queenstown", "model", "experiment", "abm_check_adapter"))
  source(file.path("R", paste0(f, ".R")))
res <- test_dir("tests/testthat", reporter = "summary", stop_on_failure = TRUE)
