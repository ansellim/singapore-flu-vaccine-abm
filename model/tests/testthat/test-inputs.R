test_that("stored inputs load with verified checksums and expected totals", {
  inp <- fixture_world()$inputs
  # 38 cells each rounded to the nearest 10 can differ from the published total by at most 190.
  expect_lte(abs(sum(inp$age_sex$count) - 4044210), 190)
  expect_equal(nrow(inp$structure_size), 64)
  expect_equal(sum(inp$older_living$persons), 622901)
  expect_equal(inp$fdw_stock$fdw[inp$fdw_stock$month == "2020-12"], 247400)
  expect_equal(nrow(inp$lfpr), 26)
  expect_false(anyNA(inp$couples$wife_lo))
})

test_that("a corrupted input file is rejected", {
  d <- tempfile(); dir.create(d)
  file.copy(list.files(evidence_dir(), full.names = TRUE), d, recursive = TRUE)
  f <- file.path(d, "age-sex-2020.json")
  writeLines(sub("4044210", "4044211", readLines(f, warn = FALSE)), f)
  withr_env <- Sys.getenv("A4_EVIDENCE_DIR"); Sys.setenv(A4_EVIDENCE_DIR = d)
  on.exit(Sys.setenv(A4_EVIDENCE_DIR = withr_env))
  expect_error(read_age_sex(), "Checksum mismatch")
})
