# Transmission model.
#
# One run simulates one arm on one synthetic world with one set of pre-drawn
# random numbers. Arms of the same epidemic share the world and the random
# numbers (common random numbers), so they differ only through vaccination.
#
# States: 0 = S, 1 = I (infected, including latent), 2 = R.
# Time: half-day steps t = 0, 1, ..., 2 * n_days - 1; even t = daytime,
# odd t = nighttime; day = t %/% 2; day 0 is a Monday.

suppressPackageStartupMessages({
  library(Matrix)
})

default_model_params <- function() {
  list(
    n_days = 155L,
    dt = 0.5,
    # Natural history (Section 5). Infectiousness over infection age follows a
    # gamma density with mean 2.6 days (generation interval, Ferguson 2005) and
    # SD 1.1 days (assumed), zero during the first day (latent period, Carrat
    # 2008), truncated at 8 days, when the individual recovers.
    gi_mean = 2.6, gi_sd = 1.1, latent_steps = 2L, recovery_steps = 16L,
    incubation_steps = 3L,             # 1.48 days (Ferguson 2005), rounded to 1.5
    p_symptomatic = 0.67,              # Carrat 2008
    rel_inf_asymptomatic = 0.57,       # Tsang 2023
    p_stay_home = 0.5,                 # assumed; robustness question
    # Transmission (calibrated): per-contact daily transmission scale tau, and
    # household per-pair contact intensity h with size exponent delta (assumed).
    tau = 0.03, h = 1.5, delta = 0.5,
    # Prior immunity (assumed design value).
    prior_immune = 0.20,
    # External exposure (Section 7, assumed scenario values, per susceptible-day).
    ext_start_day = 35L, ext_end_day = 39L, ext_hazard = 0.001,
    ext_open_hazard = 0,               # 0.0001 in the open-boundary scenario
    ext_open_end_day = Inf,            # last day of continued exposure (155 in the final-size check)
    # Vaccination (Section 8).
    ve_adult = 0.40, ve_older = 0.30, ve_child = 0.50,
    waning_baseline = 0.91,
    coverage = list(child = 0.08, a18_29 = 0.274, a30_39 = 0.241, a40_49 = 0.198,
                    a50_64 = 0.246, a65_74 = 0.526, a75p = 0.526, fdw = 0),
    campaign_start_day = 7L, campaign_end_day = 20L, protection_lag_days = 14L,
    doses_per_100_adults = 10,
    older_uptake_cap = 1,              # maximum coverage of residents aged 65+; 0.75 in the uptake-cap scenario
    # Living space (Section 6).
    gamma = 0, gamma_bounds = c(0.5, 2),
    # Domestic workers (Section 3).
    p_rest_day = 0.75, rest_weekday = 6L   # Sunday
  )
}

infectiousness_profile <- function(mp) {
  k <- 0:(mp$recovery_steps - 1L)
  shape <- (mp$gi_mean / mp$gi_sd)^2; rate <- mp$gi_mean / mp$gi_sd^2
  lo <- k * mp$dt; hi <- (k + 1) * mp$dt
  w <- pgamma(hi, shape, rate) - pgamma(lo, shape, rate)
  w[k < mp$latent_steps] <- 0
  w / sum(w) / mp$dt          # per-day infectiousness; sums to 1 over the infection
}

baseline_coverage <- function(age, fdw, cov) {
  out <- ifelse(age < 18, cov$child,
         ifelse(age < 30, cov$a18_29, ifelse(age < 40, cov$a30_39,
         ifelse(age < 50, cov$a40_49, ifelse(age < 65, cov$a50_64,
         ifelse(age < 75, cov$a65_74, cov$a75p))))))
  out[fdw] <- cov$fdw
  out
}

ve_by_age <- function(age, mp) ifelse(age < 18, mp$ve_child, ifelse(age < 65, mp$ve_adult, mp$ve_older))

# Random numbers for one epidemic, drawn once and shared by all arms.
# Streams for steps and weeks beyond the standard 155-day run (310 steps,
# 24 weeks) are drawn after all the standard streams, so a longer run shares
# every random number of the standard run and is paired with it.
draw_streams <- function(n, n_steps, n_weeks, seed, base_steps = 310L, base_weeks = 24L) {
  set.seed(seed, kind = "L'Ecuyer-CMRG")
  s1 <- min(n_steps, base_steps); w1 <- min(n_weeks, base_weeks)
  U_inf <- matrix(runif(n * s1), n, s1)
  out <- list(u_prior = runif(n), u_vax = runif(n), u_order = runif(n), u_symp = runif(n),
              u_home = runif(n), u_setting = runif(n), u_infector = runif(n))
  U_rest <- matrix(runif(n * w1), n, w1)
  if (n_steps > s1) U_inf <- cbind(U_inf, matrix(runif(n * (n_steps - s1)), n, n_steps - s1))
  if (n_weeks > w1) U_rest <- cbind(U_rest, matrix(runif(n * (n_weeks - w1)), n, n_weeks - w1))
  c(list(U_inf = U_inf), out, list(U_rest = U_rest, seed = seed))
}

# Pre-computed structures for a world (independent of arm and epidemic).
prepare_world <- function(world, rates, mp) {
  pp <- world$people; n <- nrow(pp)
  grp_matrix <- function(g) {
    ok <- !is.na(g)
    sparseMatrix(i = as.integer(factor(g[ok])), j = which(ok), x = 1,
                 dims = c(max(1L, length(unique(g[ok]))), n))
  }
  hh_size <- as.numeric(table(pp$hh_id)[as.character(pp$hh_id)])
  hh <- world$households
  # Living-space multiplier (Section 6): bounded, then normalized to a mean of 1
  # weighted by household contact opportunities (pairs of occupants).
  m_area <- rep(1, nrow(hh))
  if (mp$gamma != 0) {
    ref <- median(rep(hh$area_per_occupant, hh$occupants))
    raw <- pmin(pmax((ref / hh$area_per_occupant)^mp$gamma, mp$gamma_bounds[1]), mp$gamma_bounds[2])
    pairs <- hh$occupants * (hh$occupants - 1)
    m_area <- raw / (sum(raw * pairs) / sum(pairs))
  }
  list(
    n = n, pp = pp,
    hh_index = as.integer(factor(pp$hh_id)),
    G_hh = grp_matrix(pp$hh_id),
    hh_pair_scale = mp$h / pmax(hh_size - 1, 1)^mp$delta * m_area[match(pp$hh_id, hh$hh_id)],
    class_index = as.integer(factor(pp$class_id)),
    G_class = grp_matrix(pp$class_id),
    work_index = as.integer(factor(pp$workplace_id)),
    G_work = grp_matrix(pp$workplace_id),
    venue_index = as.integer(factor(pp$venue_id)),
    G_venue = grp_matrix(pp$venue_id),
    band = pp$band,
    venue_band_n = as.matrix(grp_matrix(pp$venue_id) %*% sparseMatrix(i = seq_len(n), j = pp$band, x = 1, dims = c(n, 16))),
    # Domestic workers' rest-day gatherings. Worlds without gathering groups
    # (the original 5,000-resident community) have a single gathering.
    gather_index = if (!"gathering_id" %in% names(pp)) ifelse(pp$fdw, 1L, NA_integer_) else pp$gathering_id,
    n_gatherings = if (!"gathering_id" %in% names(pp)) 1L else max(1L, suppressWarnings(max(pp$gathering_id, na.rm = TRUE))),
    c_school = rates$school[pp$band], c_work = rates$work[pp$band],
    C_comm = rates$community, c_gather = rates$gathering[pp$band],
    is_student = !is.na(pp$class_id), is_worker = pp$worker, is_fdw = pp$fdw,
    resident = pp$resident, age = pp$age,
    profile = infectiousness_profile(mp)
  )
}

group_sum <- function(G, x) as.numeric(G %*% x)

# Additional-dose queue for an arm. Eligible: residents aged 18+ without a
# baseline dose. Order: one shared random ordering (u_order); Arm C takes
# residents aged 65+ first. With older_cap < 1, residents aged 65+ are dropped
# from the queue once total coverage of that age group (baseline plus
# campaign) would exceed older_cap, in every arm.
dose_queue <- function(W, base_vax, arm, u_order, older_cap = 1) {
  elig <- which(W$resident & W$age >= 18 & !base_vax)
  if (arm == "A") return(integer(0))
  o <- elig[order(u_order[elig])]
  if (arm == "C") o <- c(o[W$age[o] >= 65], o[W$age[o] < 65])
  if (older_cap < 1) {
    older_res <- W$resident & W$age >= 65
    allowed <- max(0L, floor(older_cap * sum(older_res)) - sum(base_vax & older_res))
    is_older <- W$age[o] >= 65
    o <- o[!is_older | cumsum(is_older) <= allowed]
  }
  o
}

simulate_arm <- function(W, S, mp, arm = c("A", "B", "C"), record_infector = TRUE) {
  arm <- match.arg(arm)
  n <- W$n; n_steps <- 2L * mp$n_days; dt <- mp$dt
  state <- rep(0L, n)
  state[S$u_prior < mp$prior_immune] <- 2L
  initially_immune <- state == 2L
  inf_step <- rep(NA_integer_, n)
  symptomatic <- S$u_symp < mp$p_symptomatic
  stays_home <- symptomatic & (S$u_home < mp$p_stay_home)
  # Baseline vaccination at time 0, with waning.
  cov <- baseline_coverage(W$age, W$is_fdw, mp$coverage)
  base_vax <- S$u_vax < cov
  ve <- ve_by_age(W$age, mp)
  susc <- ifelse(base_vax, 1 - ve * mp$waning_baseline, 1)
  # Additional campaign.
  adults <- sum(W$resident & W$age >= 18)
  budget <- floor(mp$doses_per_100_adults / 100 * adults)
  q <- dose_queue(W, base_vax, arm, S$u_order, mp$older_uptake_cap)
  budget <- min(budget, length(q))
  campaign_days <- mp$campaign_start_day:mp$campaign_end_day
  cum <- floor(seq_along(campaign_days) * budget / length(campaign_days))
  per_day <- diff(c(0, cum))
  dose_day <- rep(NA_integer_, n)
  if (budget > 0) dose_day[q[seq_len(budget)]] <- rep(campaign_days, per_day)
  protect_day <- dose_day + mp$protection_lag_days
  extra_susc <- 1 - ve

  setting <- rep(NA_integer_, n)     # 1 home, 2 school, 3 work, 4 community, 5 gathering, 6 external
  infector <- rep(NA_integer_, n)
  counts <- matrix(0L, n_steps + 1L, 5L, dimnames = list(NULL, c("S", "I", "R", "infectious", "new")))
  counts[1, ] <- c(sum(state == 0L), sum(state == 1L), sum(state == 2L), 0L, 0L)
  prof <- W$profile

  for (t in 0:(n_steps - 1L)) {
    day <- t %/% 2L; daytime <- (t %% 2L) == 0L; wday <- day %% 7L
    weekday <- wday <= 4L
    # Vaccine protection that starts today.
    if (daytime && budget > 0) {
      newly <- which(protect_day == day)
      if (length(newly)) susc[newly] <- extra_susc[newly]
    }
    # 1. Frozen state.
    age_inf <- ifelse(state == 1L, t - inf_step, NA_integer_)
    infectious <- state == 1L & age_inf >= mp$latent_steps & age_inf < mp$recovery_steps
    w <- numeric(n)
    if (any(infectious)) {
      ii <- which(infectious)
      w[ii] <- prof[age_inf[ii] + 1L] * ifelse(symptomatic[ii], 1, mp$rel_inf_asymptomatic)
    }
    home_bound <- state == 1L & stays_home & !is.na(age_inf) & age_inf >= mp$incubation_steps
    # 2. Locations for this step.
    week <- day %/% 7L + 1L
    at_gathering <- if (daytime && wday == mp$rest_weekday) {
      W$is_fdw & S$U_rest[, week] < mp$p_rest_day & !home_bound
    } else rep(FALSE, n)
    if (!daytime) {
      at_home <- rep(TRUE, n); at_school <- at_work <- at_comm <- rep(FALSE, n)
    } else {
      at_school <- weekday & W$is_student & !home_bound
      at_work <- weekday & W$is_worker & !home_bound
      at_comm <- !home_bound & !at_gathering
      at_home <- !at_school & !at_work & !at_gathering
    }
    # 3. Exposure of susceptibles by setting (per day).
    sus <- which(state == 0L)
    if (length(sus) == 0) { counts[t + 2L, ] <- c(0L, sum(state == 1L), sum(state == 2L), sum(infectious), 0L); next }
    lam <- matrix(0, length(sus), 6L)
    if (any(w > 0)) {
      wh <- w * at_home
      hs <- group_sum(W$G_hh, wh)
      lam[, 1] <- mp$tau * W$hh_pair_scale[sus] * hs[W$hh_index[sus]] * at_home[sus]
      if (daytime && weekday) {
        ws <- w * at_school
        if (any(ws > 0)) {
          cs <- group_sum(W$G_class, ws); cn <- group_sum(W$G_class, as.numeric(at_school))
          ok <- at_school[sus]; ci <- W$class_index[sus]
          lam[ok, 2] <- mp$tau * W$c_school[sus][ok] * cs[ci[ok]] / pmax(cn[ci[ok]] - 1, 1)
        }
        ww <- w * at_work
        if (any(ww > 0)) {
          ks <- group_sum(W$G_work, ww); kn <- group_sum(W$G_work, as.numeric(at_work))
          ok <- at_work[sus]; ki <- W$work_index[sus]
          lam[ok, 3] <- mp$tau * W$c_work[sus][ok] * ks[ki[ok]] / pmax(kn[ki[ok]] - 1, 1)
        }
      }
      if (daytime) {
        wc <- w * at_comm
        if (any(wc > 0)) {
          ic <- which(wc > 0)
          Svb <- as.matrix(sparseMatrix(i = W$venue_index[ic], j = W$band[ic], x = wc[ic],
                                        dims = dim(W$venue_band_n)))
          dens <- Svb / pmax(W$venue_band_n, 1)
          ok <- at_comm[sus]; vi <- W$venue_index[sus]; bi <- W$band[sus]
          lam[ok, 4] <- mp$tau * rowSums(W$C_comm[bi[ok], , drop = FALSE] * dens[vi[ok], , drop = FALSE])
        }
        wg <- w * at_gathering
        if (any(wg > 0)) {
          ok <- at_gathering[sus]
          if (W$n_gatherings == 1L) {
            ng <- sum(at_gathering)
            lam[ok, 5] <- mp$tau * W$c_gather[sus][ok] * sum(wg) / max(ng - 1, 1)
          } else {
            g <- which(at_gathering)
            gs <- tabulate(W$gather_index[g], nbins = W$n_gatherings)
            gw <- as.numeric(tapply(wg[g], factor(W$gather_index[g], levels = seq_len(W$n_gatherings)), sum))
            gw[is.na(gw)] <- 0
            gi <- W$gather_index[sus][ok]
            lam[ok, 5] <- mp$tau * W$c_gather[sus][ok] * gw[gi] / pmax(gs[gi] - 1, 1)
          }
        }
      }
    }
    ext <- if (day >= mp$ext_start_day && day <= mp$ext_end_day) mp$ext_hazard else
      if (day > mp$ext_end_day && day <= mp$ext_open_end_day) mp$ext_open_hazard else 0
    # School, workplace, community and gathering contacts are daily totals that
    # all occur in the daytime half-step, so their rates are doubled there;
    # household exposure runs in both half-steps at its per-day intensity.
    lam[, 2:5] <- lam[, 2:5] * 2   # a full day's contacts within one half-day step
    lam[, 6] <- ext
    total <- rowSums(lam) * susc[sus]
    p <- 1 - exp(-dt * total)
    hit <- S$U_inf[sus, t + 1L] < p
    new_idx <- sus[hit]
    # 4. Commit simultaneously: recoveries from the frozen state, then infections.
    recover <- state == 1L & age_inf >= mp$recovery_steps - 1L
    state[which(recover)] <- 2L
    if (length(new_idx)) {
      state[new_idx] <- 1L
      inf_step[new_idx] <- t + 1L
      L <- lam[hit, , drop = FALSE]
      cumL <- t(apply(L, 1, cumsum))
      if (length(new_idx) == 1) cumL <- matrix(cumL, nrow = 1)
      pick <- rowSums(cumL < S$u_setting[new_idx] * cumL[, 6]) + 1L
      setting[new_idx] <- pick
      if (record_infector) infector[new_idx] <- draw_infectors(W, new_idx, pick, w, at_home, at_school,
                                                                at_work, at_comm, at_gathering, S$u_infector)
    }
    counts[t + 2L, ] <- c(sum(state == 0L), sum(state == 1L), sum(state == 2L), sum(infectious), length(new_idx))
    if (sum(counts[t + 2L, 1:3]) != n) stop("S + I + R != N at step ", t + 1L)
  }
  list(counts = counts, inf_step = inf_step, setting = setting, infector = infector,
       symptomatic = symptomatic, initially_immune = initially_immune, base_vax = base_vax,
       dose_day = dose_day, budget = budget, arm = arm)
}

# Draw each new case's infector among infectious individuals in the attributed
# setting, with probability proportional to their contribution.
# Candidates are searched among the step's infectious individuals only (in
# increasing index order, as a search over everyone would return them), so the
# cost grows with the number infectious rather than the population size.
draw_infectors <- function(W, new_idx, pick, w, at_home, at_school, at_work, at_comm, at_gathering, u) {
  out <- rep(NA_integer_, length(new_idx))
  inf <- which(w > 0)
  for (k in seq_along(new_idx)) {
    i <- new_idx[k]
    cand <- switch(pick[k],
      inf[at_home[inf] & W$hh_index[inf] == W$hh_index[i]],
      inf[at_school[inf] & W$class_index[inf] %in% W$class_index[i]],
      inf[at_work[inf] & W$work_index[inf] %in% W$work_index[i]],
      inf[at_comm[inf] & W$venue_index[inf] == W$venue_index[i]],
      inf[at_gathering[inf] & W$gather_index[inf] %in% W$gather_index[i]],
      integer(0))
    cand <- setdiff(cand, i)
    if (length(cand) == 0) next
    pr <- w[cand]
    if (pick[k] == 4L) pr <- pr * W$C_comm[W$band[i], W$band[cand]] / pmax(W$venue_band_n[cbind(W$venue_index[i], W$band[cand])], 1)
    cp <- cumsum(pr) / sum(pr)
    out[k] <- cand[min(which(cp >= u[i]))]
  }
  out
}
