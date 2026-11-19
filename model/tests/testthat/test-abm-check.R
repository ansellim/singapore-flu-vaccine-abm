test_that("the course harness abm_check() passes on the extended model", {
  setup <- normalizePath(file.path(a4_root(), "..", "..", "week10and11", "Week_1__export (2)", "SPH5105_Session10_setup.R"), mustWork = FALSE)
  skip_if_not(file.exists(setup), "course setup file not available here")
  env <- new.env(); sys.source(setup, envir = env)
  w <- fixture_world()$world
  run_fun <- make_abm_check_run_fun(w, contact_rates(w, fixture_world()$prem), calibrated_params())
  pars <- env$abm_pars(n = nrow(w$people), box = w$settings_params$box)
  out <- env$abm_check(run_fun, pars, t_max = 310, verbose = FALSE)
  expect_true(all(out$pass), info = paste(out$check[!out$pass], out$detail[!out$pass]))
})
