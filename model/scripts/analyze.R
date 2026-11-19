# Analysis of the main experiment.
# Reads every chunk in outputs/experiment and writes summary tables to
# outputs/summary and figures to outputs/figures.
# Usage: Rscript scripts/analyze.R
source("scripts/common.R"); source("scripts/scenarios.R")
suppressPackageStartupMessages({ library(ggplot2); library(patchwork) })

files <- list.files(out_dir("experiment"), "\\.rds$", full.names = TRUE)
n_pop_expected <- as.integer(Sys.getenv("A4_NPOP", unset = "30"))
expected <- nrow(merge(experiment_design(), data.frame(pop = seq_len(n_pop_expected))))
if (length(files) != expected) stop("expected ", expected, " chunks, found ", length(files))
chunks <- lapply(files, readRDS)
summ <- bind_rows(lapply(chunks, `[[`, "summary"))
strat <- bind_rows(lapply(chunks, `[[`, "strata"))
daily <- bind_rows(lapply(chunks, `[[`, "daily"))
sdir <- out_dir("summary"); fdir <- out_dir("figures")
major_threshold <- 0.05   # fixed from the pilot before the main runs

scen_order <- c(main_scenarios, added_scenarios, sensitivity_scenarios)
scen_label <- c(reference = "Reference",
                weak_older_ve = "Older-adult protection 10% (baseline and campaign)",
                null_older_ve = "Older-adult protection 0% (baseline and campaign)",
                open_boundary = "Outside exposure 0.0001 (open boundary)",
                living_space = "Living space (\u03b3 = 0.5)",
                living_space_controlled = "Living space, controlled reassignment",
                shuffled_geography = "Shuffled geography",
                open_boundary_2e5 = "Outside exposure 0.00002*",
                open_boundary_5e5 = "Outside exposure 0.00005*",
                open_boundary_2e4 = "Outside exposure 0.0002*",
                open_boundary_long = "Open boundary to day 155, followed to day 215*",
                equal_older_ve = "Older-adult protection 40% (baseline and campaign)*",
                weak_adult_ve = "Protection 20% at ages 18 to 64 (baseline and campaign)*",
                older_cap = "Older-adult coverage capped at 75%*",
                older_cap_open = "Coverage cap and open boundary*",
                child_ve_30 = "Child protection 30%", child_ve_71 = "Child protection 71%",
                cov75_406 = "Coverage at 75 and over 40.6%", cov75_60 = "Coverage at 75 and over 60%",
                child_cov_4 = "Child coverage 4%", child_cov_15 = "Child coverage 15%",
                waning_069 = "Baseline-dose waning factor 0.69", waning_none = "No waning of baseline doses",
                stay_home_25 = "Staying home 25% of symptomatic", stay_home_75 = "Staying home 75% of symptomatic")
arm_label <- c(A = "A: existing vaccination only", B = "B: broad allocation", C = "C: older adults first")

# Paired contrasts per epidemic, then population means, then the grand mean
# with its Monte Carlo standard error from the population means.
paired <- summ |>
  select(scenario, set, level, pop, epi_seed, arm, ap_older, ap_older_onward, ap_residents,
         infections_older, infections_residents, doses, peak_infectious, peak_day) |>
  pivot_wider(names_from = arm, values_from = c(ap_older, ap_older_onward, ap_residents,
                                                infections_older, infections_residents, doses,
                                                peak_infectious, peak_day))
contrast_table <- function(df, expr_name, expr) {
  df |> mutate(d = {{ expr }}) |>
    group_by(scenario, set, level, pop) |> summarise(m = mean(d, na.rm = TRUE), .groups = "drop") |>
    group_by(scenario, set, level) |>
    summarise(estimate = mean(m), mcse = sd(m) / sqrt(n()), n_pop = n(), .groups = "drop") |>
    mutate(contrast = expr_name, lo = estimate - qt(0.975, n_pop - 1) * mcse,
           hi = estimate + qt(0.975, n_pop - 1) * mcse)
}
contrasts <- bind_rows(
  contrast_table(paired, "older: C minus B", ap_older_C - ap_older_B),
  contrast_table(paired, "older: B minus A", ap_older_B - ap_older_A),
  contrast_table(paired, "older: C minus A", ap_older_C - ap_older_A),
  contrast_table(paired, "older onward only: C minus B", ap_older_onward_C - ap_older_onward_B),
  contrast_table(paired, "residents: C minus B", ap_residents_C - ap_residents_B),
  contrast_table(paired, "residents: B minus A", ap_residents_B - ap_residents_A),
  contrast_table(paired, "residents: C minus A", ap_residents_C - ap_residents_A),
  contrast_table(paired, "older infections averted per 100 doses: B", (infections_older_A - infections_older_B) / doses_B * 100),
  contrast_table(paired, "older infections averted per 100 doses: C", (infections_older_A - infections_older_C) / doses_C * 100),
  contrast_table(paired, "resident infections averted per 100 doses: B", (infections_residents_A - infections_residents_B) / doses_B * 100),
  contrast_table(paired, "resident infections averted per 100 doses: C", (infections_residents_A - infections_residents_C) / doses_C * 100)
) |> mutate(scenario = factor(scenario, scen_order))
readr::write_csv(contrasts, file.path(sdir, "contrasts.csv"))

# Arm-level means with MCSE.
arm_means <- summ |>
  pivot_longer(c(ap_older, ap_older_onward, ap_residents, ap_adult_21_75_unvax, ap_fdw,
                 peak_infectious, peak_day, hh_with_onward,
                 neighborhoods_reached, cross_neighborhood_events, gi_mean, si_mean, si_home_mean,
                 share_home, share_school, share_work, share_community, share_gathering, n_external,
                 doses, doses_older, still_infected_end),
               names_to = "measure", values_to = "value") |>
  group_by(scenario, set, level, arm, measure, pop) |> summarise(m = mean(value, na.rm = TRUE), .groups = "drop") |>
  group_by(scenario, set, level, arm, measure) |>
  summarise(mean = mean(m, na.rm = TRUE), mcse = sd(m, na.rm = TRUE) / sqrt(sum(!is.na(m))), .groups = "drop")
readr::write_csv(arm_means, file.path(sdir, "arm_means.csv"))

# Older-adult infections averted by Arm C relative to Arm B, (C - A) / (B - A),
# as a ratio of grand means with a jackknife standard error over populations.
ratio_table <- paired |>
  group_by(scenario, set, level, pop) |>
  summarise(dB = mean(ap_older_A - ap_older_B), dC = mean(ap_older_A - ap_older_C), .groups = "drop") |>
  group_by(scenario, set, level) |>
  group_modify(function(d, key) {
    est <- sum(d$dC) / sum(d$dB)
    jk <- vapply(seq_len(nrow(d)), function(i) sum(d$dC[-i]) / sum(d$dB[-i]), numeric(1))
    n <- nrow(d); se <- sqrt((n - 1) / n * sum((jk - mean(jk))^2))
    tibble(averted_B = mean(d$dB), averted_C = mean(d$dC), ratio_C_to_B = est, ratio_se = se,
           ratio_lo = est - qt(0.975, n - 1) * se, ratio_hi = est + qt(0.975, n - 1) * se)
  }) |> ungroup()
readr::write_csv(ratio_table, file.path(sdir, "averted_ratio.csv"))

# Peak timing and size among epidemics that became major outbreaks in all
# three arms, so that every arm is compared on the same epidemics
# (descriptive: the subset is defined by outcomes).
all_major <- paired |>
  filter(ap_residents_A >= major_threshold, ap_residents_B >= major_threshold, ap_residents_C >= major_threshold)
peak_major <- summ |> semi_join(all_major, by = c("scenario", "set", "level", "pop", "epi_seed")) |>
  pivot_longer(c(peak_day, peak_infectious), names_to = "measure", values_to = "value") |>
  group_by(scenario, set, level, arm, measure, pop) |> summarise(m = mean(value), k = n(), .groups = "drop") |>
  group_by(scenario, set, level, arm, measure) |>
  summarise(mean = mean(m), mcse = sd(m) / sqrt(n()), n_epidemics = sum(k), .groups = "drop")
readr::write_csv(peak_major, file.path(sdir, "peak_major.csv"))
peak_shift <- bind_rows(
  contrast_table(all_major, "peak day: B minus A", peak_day_B - peak_day_A),
  contrast_table(all_major, "peak day: C minus A", peak_day_C - peak_day_A),
  contrast_table(all_major, "peak day: C minus B", peak_day_C - peak_day_B),
  contrast_table(paired, "peak day, all epidemics: B minus A", peak_day_B - peak_day_A),
  contrast_table(paired, "peak day, all epidemics: C minus A", peak_day_C - peak_day_A))
readr::write_csv(peak_shift, file.path(sdir, "peak_shift.csv"))

# Design checks per population: dose budget, doses to older adults and the
# number of older adults without a baseline dose.
design_check <- summ |> filter(scenario == "reference", set == "R3", arm %in% c("B", "C")) |>
  group_by(arm, pop) |> summarise(doses = first(doses), doses_older = mean(doses_older), .groups = "drop") |>
  group_by(arm) |>
  summarise(doses_min = min(doses), doses_max = max(doses), doses_mean = mean(doses),
            doses_older_mean = mean(doses_older), .groups = "drop")
readr::write_csv(design_check, file.path(sdir, "design_check.csv"))

# Mean household occupants of older adults by floor-area tertile (Section 3.5).
worlds <- lapply(seq_len(n_pop_expected), function(p) readRDS(file.path(out_dir("worlds"), sprintf("world_%03d.rds", p))))
occ_area <- bind_rows(lapply(seq_along(worlds), function(p) older_strata(worlds[[p]]) |> mutate(pop = p))) |>
  group_by(area_tertile) |>
  summarise(older_adults = n(), mean_occupants = mean(occupants), .groups = "drop")
readr::write_csv(occ_area, file.path(sdir, "occupants_by_area.csv"))

# Calibration uncertainty: Monte Carlo standard error of the grid means over
# the calibration populations, and the adult attack proportion among runs
# that became major outbreaks.
cal <- bind_rows(
  readr::read_csv(file.path(sdir, "calibration_runs.csv"), show_col_types = FALSE) |> mutate(boundary = "closed"),
  readr::read_csv(file.path(sdir, "calibration_runs_open.csv"), show_col_types = FALSE) |> mutate(boundary = "open"))
cal_unc <- cal |> mutate(tau = round(tau, 2)) |> group_by(boundary) |>
  group_by(boundary, tau, h, world) |>
  summarise(m = mean(ap_adult_21_75_unvax), m_major = mean(ap_adult_21_75_unvax[ap_residents >= major_threshold]),
            p_major = mean(ap_residents >= major_threshold), .groups = "drop") |>
  group_by(boundary, tau, h) |>
  summarise(ap_adult = mean(m), ap_adult_mcse = sd(m) / sqrt(n()),
            ap_adult_major = mean(m_major, na.rm = TRUE), p_major = mean(p_major), n_worlds = n(), .groups = "drop")
readr::write_csv(cal_unc, file.path(sdir, "calibration_uncertainty.csv"))

# Effective reproduction number in Arm A from the early exponential growth of
# infected individuals in major outbreaks (reference scenario, epidemics with daily
# output), converted with the generation-interval distribution measured in the
# same runs (gamma with the observed mean and the assumed SD of 1.1 days):
# R = (1 + r * sd^2 / mean)^(mean^2 / sd^2) (Wallinga and Lipsitch 2007).
gi_obs <- arm_means |> filter(scenario == "reference", arm == "A", measure == "gi_mean") |> select(set, gi = mean)
major_runs <- summ |> filter(arm == "A", scenario == "reference", ap_residents >= major_threshold) |>
  distinct(set, pop, epi_seed)
# The fit uses the number infected (including latent) from a start day to the
# day it reaches half its peak; start days 40 and 45 are compared because the
# individuals infected externally on days 35 to 39 recover by day 47.
r_to_R <- function(r, gi) (1 + r * 1.1^2 / gi)^(gi^2 / 1.1^2)
growth <- bind_rows(lapply(c(40, 45), function(start) {
  daily |> filter(arm == "A") |> semi_join(major_runs, by = c("set", "pop", "epi_seed")) |>
    group_by(set, level, pop, epi_seed) |>
    group_modify(function(d, key) {
      peak <- max(d$I)
      w <- d |> filter(day >= start, I > 0, I <= peak / 2, day <= d$day[which.max(d$I)])
      if (nrow(w) < 5) return(tibble())
      tibble(r = unname(coef(lm(log(I) ~ day, data = w))[2]), window_days = nrow(w))
    }) |> ungroup() |>
    group_by(set, level, pop) |> summarise(r = mean(r), w = mean(window_days), k = n(), .groups = "drop") |>
    group_by(set, level) |>
    summarise(r_mean = mean(r), r_mcse = sd(r) / sqrt(n()), window_days = mean(w), n_epidemics = sum(k),
              .groups = "drop") |>
    mutate(start_day = start)
})) |>
  left_join(gi_obs, by = "set") |>
  mutate(R_eff = r_to_R(r_mean, gi),
         R_lo = r_to_R(r_mean - qt(0.975, n_pop_expected - 1) * r_mcse, gi),
         R_hi = r_to_R(r_mean + qt(0.975, n_pop_expected - 1) * r_mcse, gi))
readr::write_csv(growth, file.path(sdir, "growth_rate_R.csv"))

# Per-epidemic contrast distribution and major-outbreak decomposition.
dist <- paired |> mutate(d = ap_older_C - ap_older_B,
                         major_B = ap_residents_B >= major_threshold, major_C = ap_residents_C >= major_threshold,
                         major_A = ap_residents_A >= major_threshold,
                         pair = case_when(major_B & major_C ~ "both major", !major_B & !major_C ~ "both minor",
                                          TRUE ~ "discordant")) |>
  group_by(scenario, set, level) |>
  summarise(p_major_A = mean(major_A), p_major_B = mean(major_B), p_major_C = mean(major_C),
            share_both_major = mean(pair == "both major"), share_both_minor = mean(pair == "both minor"),
            share_discordant = mean(pair == "discordant"),
            contrast_both_major = mean(d[pair == "both major"]),
            share_Bminor_Cmajor = mean(!major_B & major_C), share_Bmajor_Cminor = mean(major_B & !major_C),
            contrast_Bminor_Cmajor = mean(d[!major_B & major_C]), contrast_Bmajor_Cminor = mean(d[major_B & !major_C]),
            contrast_both_minor = mean(d[pair == "both minor"]),
            mean_d = mean(d),
            share_C_lower = mean(d < 0), share_equal = mean(d == 0), share_B_lower = mean(d > 0),
            q05 = quantile(d, 0.05), q25 = quantile(d, 0.25), q50 = median(d), q75 = quantile(d, 0.75),
            q95 = quantile(d, 0.95), sd_epidemic = sd(d), .groups = "drop")
readr::write_csv(dist, file.path(sdir, "contrast_distribution.csv"))

# Household strata: older-adult attack by stratum and the C minus B contrast.
strata_wide <- strat |>
  select(scenario, set, level, pop, epi_seed, stratum, level_s = stratum_level, arm, n, ap) |>
  pivot_wider(names_from = arm, values_from = ap)
strata_tab <- strata_wide |>
  mutate(d = C - B) |>
  group_by(scenario, set, level, stratum, level_s, pop) |>
  summarise(m = mean(d), a = mean(A), b = mean(B), c = mean(C), n = mean(n), .groups = "drop") |>
  group_by(scenario, set, level, stratum, level_s) |>
  summarise(older_per_pop = mean(n), ap_A = mean(a), ap_B = mean(b), ap_C = mean(c),
            estimate = mean(m), mcse = sd(m) / sqrt(n()), n_pop = n(), .groups = "drop") |>
  mutate(lo = estimate - qt(0.975, n_pop - 1) * mcse, hi = estimate + qt(0.975, n_pop - 1) * mcse)
readr::write_csv(strata_tab, file.path(sdir, "strata_contrasts.csv"))

# ---------------------------------------------------------------------------
# Figures
# ---------------------------------------------------------------------------
theme_set(theme_minimal(base_size = 10) +
            theme(panel.grid.minor = element_blank(),
                  plot.background = element_rect(fill = "white", colour = NA),
                  plot.caption = element_text(hjust = 0, colour = "grey30"),
                  plot.caption.position = "plot"))
set_levels <- c("R1", "R2", "R3", "R4", "L1", "L2", "H1", "O1", "O2", "O3", "O4")
# Okabe-Ito colors (colorblind-safe); shape marks the transmission level.
# Parameter sets use colors disjoint from the arm colors (grey, blue, orange).
set_cols <- c(R1 = "#CC79A7", R2 = "#56B4E9", R3 = "#009E73", R4 = "#882255",
              L1 = "#D55E00", L2 = "#999933", H1 = "#000000",
              O1 = "#CC79A7", O2 = "#56B4E9", O3 = "#009E73", O4 = "#882255")
level_shapes <- c(reference = 16, lower = 17, higher = 15, `open-calibrated` = 18)
arm_cols <- c("#9AA5B1", "#0072B2", "#E69F00")
contrast_x <- "Arm C minus Arm B, older-adult infection attack proportion\n(percentage points; negative favors prioritizing older adults)"
pct <- function(x) x * 100
tcrit <- qt(0.975, n_pop_expected - 1)

# Figure: primary contrast across scenarios and calibrated sets.
f1 <- contrasts |> filter(contrast == "older: C minus B") |>
  mutate(label = case_when(level == "open-calibrated" & scenario == "open_boundary" ~ "Outside exposure 0.0001, recalibrated (O1 to O4)*",
                           level == "open-calibrated" ~ "Coverage cap and open boundary, recalibrated*",
                           level == "lower" ~ "Lower transmission (L1, L2)",
                           level == "higher" & scenario == "reference" ~ "Higher transmission (H1)*",
                           level == "higher" ~ "Higher transmission (H1), open boundary*",
                           TRUE ~ scen_label[as.character(scenario)]),
         group = case_when(level %in% c("lower", "higher") ~ "Transmission level",
                           grepl("open_boundary|older_cap_open", scenario) ~ "Outside exposure",
                           grepl("stay_home", scenario) ~ "Behavior",
                           grepl("ve|cap|cov|waning", scenario) ~ "Vaccine and uptake",
                           scenario == "reference" ~ "Reference",
                           TRUE ~ "Space and geography"),
         group = factor(group, c("Reference", "Outside exposure", "Vaccine and uptake", "Behavior", "Transmission level",
                                 "Space and geography")),
         set = factor(set, set_levels))
label_order <- c("Reference", scen_label[c("open_boundary_2e5", "open_boundary_5e5", "open_boundary")],
                 "Outside exposure 0.0001, recalibrated (O1 to O4)*",
                 scen_label[c("open_boundary_2e4", "open_boundary_long", "older_cap_open")],
                 "Coverage cap and open boundary, recalibrated*",
                 scen_label[c("equal_older_ve", "weak_older_ve", "null_older_ve", "weak_adult_ve", "older_cap")],
                 scen_label[sensitivity_scenarios],
                 "Lower transmission (L1, L2)", "Higher transmission (H1)*", "Higher transmission (H1), open boundary*",
                 scen_label[c("living_space", "living_space_controlled", "shuffled_geography")])
f1 <- f1 |> mutate(label = factor(label, rev(unname(label_order))))
p1 <- ggplot(f1, aes(x = pct(estimate), y = label, colour = set, shape = level)) +
  geom_vline(xintercept = 0, colour = "grey40") +
  geom_pointrange(aes(xmin = pct(lo), xmax = pct(hi)), position = position_dodge(width = 0.7), size = 0.25) +
  facet_grid(group ~ ., scales = "free_y", space = "free_y", switch = "y") +
  scale_colour_manual(values = set_cols, breaks = c("R1", "R2", "R3", "R4", "L1", "L2", "H1")) +
  scale_shape_manual(values = level_shapes) +
  scale_x_continuous(breaks = seq(-1, 2, by = 0.5)) +
  theme(strip.placement = "outside", strip.text.y.left = element_text(angle = 0, face = "bold", hjust = 1)) +
  labs(x = contrast_x, y = NULL, colour = "Parameter set", shape = "Transmission level",
       caption = paste("Points: mean over 30 populations x 50 paired epidemics; bars: 95% Monte Carlo intervals (simulation error only).",
                       "\nOutside exposure is per susceptible person-day after day 39. Sets O1 to O4 (diamonds) use the colors of R1 to R4.",
                       "\n* Scenario or set added after the first results.")) +
  guides(colour = guide_legend(reverse = TRUE))
ggsave(file.path(fdir, "fig_primary_contrast.png"), p1, width = 9, height = 10, dpi = 200)

# Figure: contrast and major-outbreak probability across the outside-exposure gradient.
grad_scen <- c(reference = 0, open_boundary_2e5 = 2e-5, open_boundary_5e5 = 5e-5, open_boundary = 1e-4,
               open_boundary_2e4 = 2e-4)
g1 <- contrasts |> filter(contrast == "older: C minus B", scenario %in% names(grad_scen), level == "reference") |>
  mutate(hazard = grad_scen[as.character(scenario)], set = factor(set, set_levels))
g2 <- dist |> filter(scenario %in% names(grad_scen), level == "reference") |>
  select(scenario, set, A = p_major_A, B = p_major_B, C = p_major_C) |>
  pivot_longer(c(A, B, C), names_to = "arm", values_to = "p") |>
  mutate(hazard = grad_scen[as.character(scenario)], arm = arm_label[arm])
xlab_h <- "Continued outside exposure (infections per 100,000 susceptible person-days, after day 39)"
hazard_axis <- scale_x_continuous(breaks = c(0, 2, 5, 10, 20))
pg1 <- ggplot(g1, aes(x = hazard * 1e5, y = pct(estimate), colour = set, group = set)) +
  geom_hline(yintercept = 0, colour = "grey40") +
  geom_line(position = position_dodge(width = 0.6), linewidth = 0.4) +
  geom_pointrange(aes(ymin = pct(lo), ymax = pct(hi)), position = position_dodge(width = 0.6), size = 0.25) +
  hazard_axis +
  scale_colour_manual(values = set_cols) +
  labs(x = NULL, y = "C minus B, older adults\n(percentage points)", colour = "Parameter set",
       title = "A. Difference between campaigns")
pg2 <- ggplot(g2 |> group_by(hazard, arm) |> summarise(p = mean(p), .groups = "drop"),
              aes(x = hazard * 1e5, y = p, colour = arm, group = arm)) +
  geom_line(linewidth = 0.5) + geom_point(size = 1.6) + hazard_axis +
  scale_colour_manual(values = arm_cols) + scale_y_continuous(limits = c(0.75, 1)) +
  labs(x = xlab_h, y = "Probability of a major outbreak", colour = NULL,
       title = "B. Major outbreaks (mean of sets R1 to R4)",
       caption = paste("Exposure 0 is the reference scenario (introductions on days 35 to 39 only); levels 2, 5 and 20 were added after the first results.",
                       "\nBars: 95% Monte Carlo intervals. Note that the vertical axis of panel B starts at 0.75."))
ggsave(file.path(fdir, "fig_outside_exposure.png"), pg1 / pg2, width = 8, height = 6.5, dpi = 200)

# Figure: arm-level outcomes, reference scenario. Peak timing and size are
# shown for epidemics that became major outbreaks in that arm.
f2a <- arm_means |> filter(scenario == "reference", measure %in% c("ap_older", "ap_residents")) |>
  mutate(mean = pct(mean), mcse = pct(mcse))
f2b <- peak_major |> filter(scenario == "reference")
f2 <- bind_rows(f2a, f2b) |>
  mutate(measure = factor(recode(measure, ap_older = "Attack proportion, residents 65+ (%)",
                                 ap_residents = "Attack proportion, all residents (%)",
                                 peak_infectious = "Peak infectious individuals (major in all arms)",
                                 peak_day = "Day of peak (major in all arms)"),
                          c("Attack proportion, residents 65+ (%)", "Attack proportion, all residents (%)",
                            "Peak infectious individuals (major in all arms)", "Day of peak (major in all arms)")),
         arm = arm_label[arm], set = factor(set, set_levels))
p2 <- ggplot(f2, aes(x = set, y = mean, colour = arm)) +
  geom_pointrange(aes(ymin = mean - tcrit * mcse, ymax = mean + tcrit * mcse),
                  position = position_dodge(width = 0.6), size = 0.25) +
  facet_wrap(~ measure, scales = "free_y", nrow = 2) +
  scale_colour_manual(values = arm_cols) +
  labs(x = "Parameter set", y = NULL, colour = NULL,
       caption = paste("Reference scenario; mean over 30 populations x 50 epidemics. Bars: 95% Monte Carlo intervals for each arm's mean;",
                       "they ignore the pairing of arms,\nso compare arms with the paired contrasts (Figure 6).",
                       "Peak panels use only epidemics with at least 5% of residents infected in all three arms.")) +
  theme(legend.position = "bottom")
ggsave(file.path(fdir, "fig_attack_by_arm.png"), p2, width = 8.5, height = 6, dpi = 200)

# Figure: daily S, I, R and infectious prevalence (reference scenario, set R3,
# all runs saved with daily output, each line one epidemic).
f3 <- daily |> filter(set == "R3") |>
  pivot_longer(c(S, I, R, infectious), names_to = "state", values_to = "count") |>
  mutate(state = factor(recode(state, infectious = "Infectious"), levels = c("S", "I", "R", "Infectious")),
         arm = arm_label[arm])
med3 <- f3 |> group_by(arm, state, day) |> summarise(count = median(count), .groups = "drop")
p3 <- ggplot(f3, aes(x = day, y = count, colour = arm)) +
  geom_rect(data = data.frame(arm = arm_label[c("B", "C")], xmin = 21, xmax = 34, ymin = -Inf, ymax = Inf),
            aes(xmin = xmin, xmax = xmax, ymin = ymin, ymax = ymax), inherit.aes = FALSE, alpha = 0.08) +
  geom_line(aes(group = interaction(pop, epi_seed)), alpha = 0.10, linewidth = 0.3) +
  geom_line(data = med3, colour = "black", linewidth = 0.7) +
  facet_grid(state ~ arm, scales = "free_y") +
  scale_colour_manual(values = arm_cols, guide = "none") +
  geom_vline(data = expand.grid(arm = arm_label[c("B", "C")], x = c(7, 20)), aes(xintercept = x),
             linetype = "dotted", colour = "grey40") +
  geom_vline(xintercept = 35, linetype = "dotted", colour = "grey40") +
  labs(x = "Model day", y = "Number of individuals",
       caption = paste("Set R3, reference scenario; 300 epidemics per arm (30 populations x 10), one thin line each; black line: pointwise median across epidemics.",
                       "\nI: infected, including the latent period. R includes the 20% of individuals immune at the start.",
                       "\nDotted lines: campaign start (day 7) and end (day 20), and first introductions (day 35). Shading: campaign doses become protective (days 21 to 34)."))
ggsave(file.path(fdir, "fig_daily_sir.png"), p3, width = 9, height = 7, dpi = 200)

# Figure: household-stratum contrasts, reference and no-older-protection scenarios.
lab_s <- c(alone = "Living alone", spouse_only = "Spouse only", with_own_children = "With own children",
           other = "Other arrangement", fdw = "Domestic worker present", no_fdw = "No domestic worker",
           with_under18 = "With someone under 18", no_under18 = "No one under 18",
           low = "Lowest third", mid = "Middle third", high = "Highest third",
           `2` = "2 occupants", `3` = "3", `4` = "4", `5` = "5 or more")
f4 <- strata_tab |> filter(scenario %in% c("reference", "null_older_ve"), level == "reference",
                           !(stratum == "occupants" & level_s == "1")) |>
  mutate(stratum = factor(recode(stratum, arrangement = "Living arrangement", domestic_worker = "Domestic worker",
                                 under18 = "Co-resident under 18", occupants = "Household occupants",
                                 area = "Floor area per occupant"),
                          c("Living arrangement", "Household occupants", "Co-resident under 18", "Domestic worker",
                            "Floor area per occupant")),
         scenario = factor(recode(scenario, reference = "Reference", null_older_ve = "Older-adult protection 0%"),
                           c("Reference", "Older-adult protection 0%")),
         level_lab = factor(lab_s[level_s], levels = rev(unname(lab_s))),
         set = factor(set, set_levels))
p4 <- ggplot(f4, aes(x = pct(estimate), y = level_lab, colour = set)) +
  geom_vline(xintercept = 0, colour = "grey40") +
  geom_vline(data = data.frame(scenario = factor("Older-adult protection 0%", levels(f4$scenario)), x = 2),
             aes(xintercept = x), linetype = "dashed", colour = "grey40") +
  geom_pointrange(aes(xmin = pct(lo), xmax = pct(hi)), position = position_dodge(width = 0.6), size = 0.2) +
  facet_grid(stratum ~ scenario, scales = "free", space = "free_y") +
  guides(colour = guide_legend(reverse = TRUE)) +
  scale_colour_manual(values = set_cols) +
  theme(strip.text.y = element_text(angle = 0, hjust = 0)) +
  labs(x = contrast_x, y = NULL, colour = "Parameter set",
       caption = paste("Strata defined at baseline; living alone is the 1-occupant stratum. Note the different horizontal scales.",
                       "\n95% Monte Carlo intervals over 30 populations; descriptive, 15 strata x 2 scenarios x 4 sets. Dashed line: 2 points."))
ggsave(file.path(fdir, "fig_strata_contrast.png"), p4, width = 10, height = 7.5, dpi = 200)

# Figure: distribution of per-epidemic paired contrasts, reference scenario.
# One older adult is about 100 / 757 = 0.13 points, so bins are one older adult wide.
step <- 100 / 757
f5 <- paired |> filter(scenario == "reference") |>
  mutate(d = pct(ap_older_C - ap_older_B), set = factor(set, set_levels),
         major_B = ap_residents_B >= major_threshold, major_C = ap_residents_C >= major_threshold,
         pair = factor(case_when(major_B & major_C ~ "Both major", !major_B & !major_C ~ "Both minor",
                                 !major_B & major_C ~ "Major under C only", TRUE ~ "Major under B only"),
                       c("Both major", "Both minor", "Major under C only", "Major under B only")))
means5 <- f5 |> group_by(set) |> summarise(m = mean(d), .groups = "drop")
x_lim5 <- c(-6, 8)
n_out5 <- f5 |> group_by(set) |> summarise(k = sum(d < x_lim5[1] | d > x_lim5[2]), .groups = "drop")
p5 <- ggplot(f5, aes(x = d, fill = pair)) +
  geom_histogram(binwidth = step, boundary = step / 2) +
  geom_vline(xintercept = 0, colour = "grey20", linewidth = 0.4) +
  geom_vline(data = means5, aes(xintercept = m), linetype = "dashed", colour = "#D55E00", linewidth = 0.5) +
  facet_wrap(~ set, nrow = 2, scales = "free_y") +
  scale_fill_manual(values = c("Both major" = "grey35", "Both minor" = "grey75",
                               "Major under C only" = "#E69F00", "Major under B only" = "#0072B2")) +
  coord_cartesian(xlim = x_lim5) +
  labs(x = "Per-epidemic difference, Arm C minus Arm B, older-adult attack proportion (percentage points)",
       y = "Epidemics", fill = "Major outbreak (5% or more of residents)",
       caption = paste0("Reference scenario; 1,500 paired epidemics per set; L1 and L2: lower transmission level; H1: higher, not calibrated. ",
                        "\nSolid line: zero; dashed line: mean. Bins are about one older adult wide. Axis truncated at -6 and +8 points; epidemics outside: ",
                        paste(sprintf("%s %d", n_out5$set, n_out5$k), collapse = ", "), ".")) +
  theme(legend.position = "bottom")
ggsave(file.path(fdir, "fig_contrast_histogram.png"), p5, width = 9, height = 5.5, dpi = 200)
cat("analysis complete:", nrow(summ), "arm runs\n")
