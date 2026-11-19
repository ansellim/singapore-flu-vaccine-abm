# Adapter between the course verification harness abm_check() (Session 10
# setup file) and this model.
#
# abm_check() calls run_fun(pars, seed, t_max) with an abm_pars object and
# expects list(ts = data.frame(t, S, I, R), final = data.frame(x, y)).
# It builds its zero-transmission case by calling abm_pars(..., p_low = 0,
# p_high = 0); the adapter maps that case to zero transmission inside the
# community AND zero external hazard, because introductions from outside would
# otherwise appear as transmission. Individuals who start in R (prior immunity) are
# counted by abm_check as "seeded", which is how the harness treats initial R.
#
# Steps are the model's half-day steps; positions in `final` are the individuals'
# locations at the last step (home coordinates at night, in meters).

make_abm_check_run_fun <- function(world, rates, mp_ref, arm = "C") {
  function(pars, seed, t_max = 40) {
    mp <- mp_ref
    if (isTRUE(pars$p_low == 0 && pars$p_high == 0)) {
      mp$tau <- 0; mp$ext_hazard <- 0; mp$ext_open_hazard <- 0
    }
    mp$n_days <- as.integer(ceiling(t_max / 2))
    W <- prepare_world(world, rates, mp)
    if (W$n != pars$n) stop("abm_check pars$n (", pars$n, ") must equal the model population (", W$n, ")")
    S <- draw_streams(W$n, 2L * mp$n_days, ceiling(mp$n_days / 7) + 1L, seed)
    r <- simulate_arm(W, S, mp, arm, record_infector = FALSE)
    k <- seq_len(t_max + 1L)
    ts <- data.frame(t = 0:t_max, S = r$counts[k, "S"], I = r$counts[k, "I"], R = r$counts[k, "R"])
    # The last simulated step is a night step only when t_max is even; at a
    # daytime step individuals are placed at their setting coordinates.
    final <- individual_positions(world, daytime = (t_max %% 2L) == 1L)
    list(ts = ts, final = final)
  }
}

# Locations of individuals at a step: home at night; school site, workplace or
# community venue in the daytime (weekday convention).
individual_positions <- function(world, daytime) {
  pp <- world$people
  x <- pp$home_x; y <- pp$home_y
  if (daytime) {
    s <- !is.na(pp$school_site)
    x[s] <- world$sites$x[match(pp$school_site[s], world$sites$site_id)]
    y[s] <- world$sites$y[match(pp$school_site[s], world$sites$site_id)]
    w <- !is.na(pp$workplace_id)
    x[w] <- world$workplaces$x[pp$workplace_id[w]]
    y[w] <- world$workplaces$y[pp$workplace_id[w]]
    o <- !s & !w
    x[o] <- world$venues$x[pp$venue_id[o]]
    y[o] <- world$venues$y[pp$venue_id[o]]
  }
  data.frame(x = x, y = y)
}
