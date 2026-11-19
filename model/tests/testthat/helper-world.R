# Realistic fixture: one accepted synthetic world built from the stored
# Census inputs (no mocks), cached for the test session.
fixture_world <- local({
  cache <- NULL
  function() {
    if (is.null(cache)) {
      inp <- load_inputs()
      cache <<- list(world = build_world(7L, inp), inputs = inp, prem = load_prem_sgp())
    }
    cache
  }
})
calibrated_params <- function() {
  mp <- default_model_params(); mp$tau <- 0.30; mp$h <- 1.0; mp
}
