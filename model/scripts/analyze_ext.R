# Analysis of the full-scale extension (Part 1: synthetic square; Part 2:
# Queenstown), with the original 5,000-resident community for comparison.
# Usage: Rscript scripts/analyze_ext.R n_pop
source("scripts/common.R"); source("scripts/scenarios.R")
suppressPackageStartupMessages({ library(ggplot2); library(patchwork) })

n_pop <- as.integer(commandArgs(trailingOnly = TRUE)[1])
# Chunk directories under A4_OUT (comma-separated in A4_EXT_DIRS); the
# reported analysis read the single directory of the corrected rerun.
ext_dirs <- strsplit(Sys.getenv("A4_EXT_DIRS", unset = "experiment_ext"), ",")[[1]]
files <- unlist(lapply(ext_dirs, function(d)
  list.files(file.path(Sys.getenv("A4_OUT", unset = "../outputs"), d), "\\.rds$", full.names = TRUE)))
expected <- nrow(merge(extension_design(), data.frame(pop = seq_len(n_pop))))
partial <- nzchar(Sys.getenv("A4_PARTIAL"))   # for checking the script on unfinished runs only
# With A4_STOPPED set, the runs were stopped at the compute deadline: every
# scenario-set combination is analyzed on the populations completed in both
# geographies, and the number of populations is reported for each.
stopped <- nzchar(Sys.getenv("A4_STOPPED"))
if (length(files) != expected && !partial && !stopped) stop("expected ", expected, " chunks, found ", length(files))
if (partial) { sdir0 <- out_dir("summary_partial"); fdir0 <- out_dir("figures_partial") }
chunks <- lapply(files, readRDS)
if (partial || stopped) {
  key <- sub("^(square|queenstown)__", "", basename(files))
  both <- names(which(table(key) == 2))
  keep <- key %in% both
  cat("using", sum(keep), "of", length(files), "chunks (complete in both geographies)\n")
  chunks <- chunks[keep]
}
summ <- bind_rows(lapply(chunks, `[[`, "summary"))
nbhd <- bind_rows(lapply(chunks, `[[`, "neighborhood"))
strat <- bind_rows(lapply(chunks, `[[`, "strata"))
daily <- bind_rows(lapply(chunks, `[[`, "daily"))
sdir <- out_dir("summary"); fdir <- out_dir("figures")
orig_contrasts <- Sys.getenv("A4_ORIG_CONTRASTS", unset = file.path(sdir, "contrasts.csv"))
if (partial) { sdir <- sdir0; fdir <- fdir0 }
major_threshold <- 0.05

geo_label <- c(community = "Original community (5,000 residents, 4 km square)",
               square = "Part 1: synthetic square (Queenstown population and area)",
               queenstown = "Part 2: Queenstown planning area")
scen_label <- c(reference = "Reference", open_boundary = "Outside exposure 0.0001",
                shuffled_geography = "Shuffled destinations", older_cap_open = "Coverage cap 75%, outside exposure",
                weak_older_ve = "Older-adult protection 10%", equal_older_ve = "Older-adult protection 40%")

paired <- summ |>
  select(geography, scenario, set, level, pop, epi_seed, arm, ap_older, ap_residents, ap_adult_21_75_unvax,
         infections_older, infections_residents, doses, peak_infectious, peak_day) |>
  pivot_wider(names_from = arm, values_from = c(ap_older, ap_residents, ap_adult_21_75_unvax, infections_older,
                                                infections_residents, doses, peak_infectious, peak_day))
contrast_table <- function(df, name, expr) {
  df |> mutate(d = {{ expr }}) |>
    group_by(geography, scenario, set, level, pop) |> summarise(m = mean(d, na.rm = TRUE), .groups = "drop") |>
    group_by(geography, scenario, set, level) |>
    summarise(estimate = mean(m), mcse = sd(m) / sqrt(n()), n_pop = n(), .groups = "drop") |>
    mutate(contrast = name, lo = estimate - qt(0.975, n_pop - 1) * mcse, hi = estimate + qt(0.975, n_pop - 1) * mcse)
}
contrasts <- bind_rows(
  contrast_table(paired, "older: C minus B", ap_older_C - ap_older_B),
  contrast_table(paired, "older: B minus A", ap_older_B - ap_older_A),
  contrast_table(paired, "older: C minus A", ap_older_C - ap_older_A),
  contrast_table(paired, "residents: C minus B", ap_residents_C - ap_residents_B),
  contrast_table(paired, "residents: B minus A", ap_residents_B - ap_residents_A),
  contrast_table(paired, "resident infections averted per 100 doses: B", (infections_residents_A - infections_residents_B) / doses_B * 100),
  contrast_table(paired, "resident infections averted per 100 doses: C", (infections_residents_A - infections_residents_C) / doses_C * 100),
  contrast_table(paired, "older infections averted per 100 doses: B", (infections_older_A - infections_older_B) / doses_B * 100),
  contrast_table(paired, "older infections averted per 100 doses: C", (infections_older_A - infections_older_C) / doses_C * 100))
readr::write_csv(contrasts, file.path(sdir, "ext_contrasts.csv"))
readr::write_csv(summ |> filter(arm == "A") |> group_by(geography, scenario, set) |>
                   summarise(n_populations = n_distinct(pop), n_epidemics = n(), .groups = "drop"),
                 file.path(sdir, "ext_design_completed.csv"))

# Geography effect on the primary contrast: Part 2 minus Part 1, paired by
# population and epidemic seed (the same populations and random numbers).
geo_diff <- paired |> mutate(d = ap_older_C - ap_older_B) |>
  select(geography, scenario, set, pop, epi_seed, d) |>
  pivot_wider(names_from = geography, values_from = d) |>
  group_by(scenario, set, pop) |> summarise(m = mean(queenstown - square), .groups = "drop") |>
  group_by(scenario, set) |>
  summarise(estimate = mean(m), mcse = sd(m) / sqrt(n()), n_pop = n(), .groups = "drop") |>
  mutate(lo = estimate - qt(0.975, n_pop - 1) * mcse, hi = estimate + qt(0.975, n_pop - 1) * mcse)
readr::write_csv(geo_diff, file.path(sdir, "ext_geography_difference.csv"))

arm_means <- summ |>
  pivot_longer(c(ap_older, ap_residents, ap_adult_21_75_unvax, ap_fdw, peak_infectious, peak_day,
                 neighborhoods_reached, cross_neighborhood_events, gi_mean, share_home, share_school, share_work,
                 share_community, share_gathering, n_external, doses, doses_older, still_infected_end),
               names_to = "measure", values_to = "value") |>
  group_by(geography, scenario, set, level, arm, measure, pop) |> summarise(m = mean(value, na.rm = TRUE), .groups = "drop") |>
  group_by(geography, scenario, set, level, arm, measure) |>
  summarise(mean = mean(m, na.rm = TRUE), mcse = sd(m, na.rm = TRUE) / sqrt(sum(!is.na(m))), .groups = "drop")
readr::write_csv(arm_means, file.path(sdir, "ext_arm_means.csv"))
p_major <- summ |> group_by(geography, scenario, set, arm) |>
  summarise(p_major = mean(ap_residents >= major_threshold), .groups = "drop")
readr::write_csv(p_major, file.path(sdir, "ext_p_major.csv"))

ratio_table <- paired |>
  group_by(geography, scenario, set, level, pop) |>
  summarise(dB = mean(ap_older_A - ap_older_B), dC = mean(ap_older_A - ap_older_C), .groups = "drop") |>
  group_by(geography, scenario, set, level) |>
  group_modify(function(d, key) {
    est <- sum(d$dC) / sum(d$dB)
    jk <- vapply(seq_len(nrow(d)), function(i) sum(d$dC[-i]) / sum(d$dB[-i]), numeric(1))
    n <- nrow(d); se <- sqrt((n - 1) / n * sum((jk - mean(jk))^2))
    tibble(averted_B = mean(d$dB), averted_C = mean(d$dC), ratio_C_to_B = est, ratio_se = se)
  }) |> ungroup()
readr::write_csv(ratio_table, file.path(sdir, "ext_averted_ratio.csv"))

# Share of the C minus B difference from epidemics that were minor under B
# but major under C (as in the original analysis).
contrast_dist <- paired |> mutate(d = ap_older_C - ap_older_B,
  type = case_when(ap_residents_B < major_threshold & ap_residents_C >= major_threshold ~ "B minor, C major",
                   ap_residents_B >= major_threshold & ap_residents_C < major_threshold ~ "B major, C minor",
                   ap_residents_B >= major_threshold ~ "both major", TRUE ~ "both minor")) |>
  group_by(geography, scenario, set) |>
  summarise(share_Bminor_Cmajor = mean(type == "B minor, C major"), share_Bmajor_Cminor = mean(type == "B major, C minor"),
            mean_d_both_major = mean(d[type == "both major"]), .groups = "drop")
readr::write_csv(contrast_dist, file.path(sdir, "ext_contrast_distribution.csv"))

# Household strata of the primary contrast (Part 2 and Part 1).
strata_cb <- strat |> select(geography, scenario, set, pop, epi_seed, arm, stratum, stratum_level, ap) |>
  pivot_wider(names_from = arm, values_from = ap) |>
  group_by(geography, scenario, set, stratum, stratum_level, pop) |>
  summarise(m = mean(C - B, na.rm = TRUE), a = mean(A, na.rm = TRUE), .groups = "drop") |>
  group_by(geography, scenario, set, stratum, stratum_level) |>
  summarise(ap_A = mean(a), estimate = mean(m), mcse = sd(m) / sqrt(n()), .groups = "drop")
readr::write_csv(strata_cb, file.path(sdir, "ext_strata_contrasts.csv"))

# Subzone (neighborhood) attack among older residents and all residents by
# arm, pooled over epidemics, and the C minus B differences with
# population-level MCSE.
nb_tab <- nbhd |> group_by(geography, scenario, set, pop, neighborhood, arm) |>
  summarise(older = sum(older), older_infected = sum(older_infected), residents = sum(residents),
            infected = sum(infected), .groups = "drop") |>
  mutate(ap_older = older_infected / pmax(older, 1), ap_res = infected / pmax(residents, 1))
nb_contrast <- nb_tab |> select(geography, scenario, set, pop, neighborhood, arm, ap_older, ap_res) |>
  pivot_wider(names_from = arm, values_from = c(ap_older, ap_res)) |>
  group_by(geography, scenario, set, neighborhood) |>
  summarise(ap_older_A = mean(ap_older_A), ap_res_A = mean(ap_res_A),
            d_CB = mean(ap_older_C - ap_older_B), d_CB_mcse = sd(ap_older_C - ap_older_B) / sqrt(n()),
            d_CB_res = mean(ap_res_C - ap_res_B), .groups = "drop")
readr::write_csv(nb_contrast, file.path(sdir, "ext_neighborhood_contrasts.csv"))

# Comparison table across the three versions for the scenarios they share.
orig <- readr::read_csv(orig_contrasts, show_col_types = FALSE) |>
  filter(contrast == "older: C minus B", scenario %in% names(scen_label),
         set %in% c(paste0("R", 1:4), paste0("O", 1:4))) |>
  mutate(geography = "community") |> select(geography, scenario, set, estimate, lo, hi)
cmp <- bind_rows(orig, contrasts |> filter(contrast == "older: C minus B") |> select(geography, scenario, set, estimate, lo, hi)) |>
  mutate(geography = factor(geography, names(geo_label)), scenario = factor(scenario, names(scen_label)))
readr::write_csv(cmp, file.path(sdir, "ext_comparison.csv"))

# ---------------------------------------------------------------------------
# Figures
# ---------------------------------------------------------------------------
geo_cols <- c(community = "#999999", square = "#0072B2", queenstown = "#D55E00")
g1 <- ggplot(cmp, aes(estimate * 100, set, colour = geography)) +
  geom_vline(xintercept = 0, colour = "gray50") +
  geom_pointrange(aes(xmin = lo * 100, xmax = hi * 100), position = position_dodge(width = 0.6), size = 0.3) +
  facet_wrap(~ scenario, ncol = 2, labeller = labeller(scenario = scen_label), scales = "free") +
  scale_colour_manual(values = geo_cols, labels = geo_label, name = NULL) +
  labs(x = "Older-adult attack proportion, Arm C minus Arm B (percentage points)", y = "Parameter set",
       caption = "Points: mean of population means; bars: 95% Monte Carlo intervals over populations. Negative values favor prioritization.") +
  theme_bw(base_size = 10) + theme(legend.position = "bottom", legend.direction = "vertical")
ggsave(file.path(fdir, "fig_ext_contrast.png"), g1, width = 8, height = 8.5, dpi = 200)

# Maps of one population in each geography.
map_pop <- as.integer(Sys.getenv("A4_MAP_POP", unset = "1"))
w_sq <- readRDS(file.path(out_dir("worlds_square"), sprintf("world_%03d.rds", map_pop)))
w_qt <- readRDS(file.path(out_dir("worlds_queenstown"), sprintf("world_%03d.rds", map_pop)))
km <- function(v, o) (v - o) / 1000
map_panel <- function(w, title, ox, oy) {
  hh <- w$households
  p <- ggplot()
  if (!is.null(w$boundary)) {
    p <- p + geom_polygon(data = w$boundary |> filter(level == "subzone"), aes(km(x, ox), km(y, oy), group = paste(id, part)),
                          fill = NA, colour = "gray60", linewidth = 0.25) +
      geom_polygon(data = w$boundary |> filter(level == "planning_area"), aes(km(x, ox), km(y, oy), group = part),
                   fill = NA, colour = "black", linewidth = 0.5)
  }
  sites <- w$sites |> mutate(kind = recode(type, preschool = "Preschool", primary = "Primary school",
                                           secondary = "Secondary school", tertiary = "Tertiary institution"))
  # Households are colored by neighborhood (Part 1) or subzone (Part 2); too many
  # areas for a color key, so the legend shows one generic household symbol.
  p + geom_point(data = hh, aes(km(x, ox), km(y, oy), colour = factor(neighborhood)), size = 0.15, alpha = 0.4, show.legend = FALSE) +
    geom_point(data = hh[1, ], aes(km(x, ox), km(y, oy), shape = "Household (color = neighborhood or subzone)"),
               size = 0.15, alpha = 0) +
    geom_point(data = w$venue_sites, aes(km(x, ox), km(y, oy), shape = "Community venue"), size = 1.6, colour = "black") +
    geom_point(data = sites, aes(km(x, ox), km(y, oy), shape = kind), size = 1.6, colour = "black", fill = "white") +
    scale_shape_manual(values = c("Household (color = neighborhood or subzone)" = 16, "Community venue" = 17, "Preschool" = 1,
                                  "Primary school" = 22, "Secondary school" = 23, "Tertiary institution" = 8), name = NULL,
                       breaks = c("Household (color = neighborhood or subzone)", "Community venue", "Preschool",
                                  "Primary school", "Secondary school", "Tertiary institution")) +
    guides(shape = guide_legend(override.aes = list(alpha = 1, size = 2,
                                                    colour = c("#3E9BFE", rep("black", 5))))) +
    scale_colour_viridis_d(option = "turbo") +
    coord_equal() + labs(title = title, x = "km", y = "km") + theme_bw(base_size = 9) + theme(legend.position = "bottom")
}
bx <- range(w_qt$boundary$x); by <- range(w_qt$boundary$y)
m1 <- map_panel(w_sq, "Part 1: synthetic square", 0, 0)
m2 <- map_panel(w_qt, "Part 2: Queenstown (SVY21, km from the area's south-west corner)", bx[1], by[1])
ggsave(file.path(fdir, "fig_ext_maps.png"), (m1 | m2) + plot_layout(guides = "collect") & theme(legend.position = "bottom"),
       width = 11, height = 6, dpi = 200)

# Subzone maps for Part 2: older-adult attack under Arm A and C minus B,
# reference scenario and set R3, and outside exposure with set O3.
centroid <- w_qt$boundary |> filter(level == "subzone") |> group_by(id) |> summarise(cx = mean(x), cy = mean(y))
nbq <- nb_contrast |> filter(geography == "queenstown", (scenario == "reference" & set == "R3") | (scenario == "open_boundary" & set == "O3")) |>
  mutate(id = w_qt$neighborhoods[neighborhood],
         panel = factor(ifelse(scenario == "reference", "Reference, set R3", "Outside exposure, set O3"),
                        c("Reference, set R3", "Outside exposure, set O3")))
# Subzones with fewer than 1,000 residents are left blank (their attack
# proportions rest on very few people).
small <- queenstown_inputs()$subzones |> filter(residents < 1000) |> pull(subzone)
nbq <- nbq |> mutate(ap_older_A = ifelse(id %in% small, NA, ap_older_A), d_CB = ifelse(id %in% small, NA, d_CB))
poly <- w_qt$boundary |> filter(level == "subzone") |> inner_join(nbq, by = "id", relationship = "many-to-many")
pa_line <- w_qt$boundary |> filter(level == "planning_area")
f_a <- ggplot(poly, aes(km(x, bx[1]), km(y, by[1]), group = paste(id, part))) +
  geom_polygon(aes(fill = ap_older_A * 100), colour = "gray70", linewidth = 0.2) +
  geom_polygon(data = pa_line, aes(group = part), fill = NA, colour = "black", linewidth = 0.4) +
  facet_wrap(~ panel) + coord_equal() + scale_fill_viridis_c(name = "Older-adult attack, Arm A (%)", na.value = "white") +
  labs(x = "km", y = "km") + theme_bw(base_size = 9) + theme(legend.position = "bottom")
lim <- max(abs(poly$d_CB), na.rm = TRUE) * 100
f_d <- ggplot(poly, aes(km(x, bx[1]), km(y, by[1]), group = paste(id, part))) +
  geom_polygon(aes(fill = d_CB * 100), colour = "white", linewidth = 0.2) +
  geom_polygon(data = pa_line, aes(group = part), fill = NA, colour = "black", linewidth = 0.4) +
  facet_wrap(~ panel) + coord_equal() +
  scale_fill_gradient2(low = "#0072B2", mid = "white", high = "#D55E00", limits = c(-lim, lim), na.value = "white",
                       name = "Older-adult attack, C minus B (points)") +
  labs(x = "km", y = "km", caption = "Subzones with fewer than 1,000 residents are left blank. Negative values favor prioritization.") +
  theme_bw(base_size = 9) + theme(legend.position = "bottom")
ggsave(file.path(fdir, "fig_ext_subzones.png"), f_a / f_d, width = 8.5, height = 8.5, dpi = 200)

# Epidemic curves: median infectious prevalence by arm and geography (set R3 and O3).
dcur <- daily |> filter((scenario == "reference" & set == "R3") | (scenario == "open_boundary" & set == "O3")) |>
  group_by(geography, scenario, arm, day) |> summarise(infectious = median(infectious), .groups = "drop")
g_c <- ggplot(dcur, aes(day, infectious, colour = arm)) + geom_line() +
  facet_grid(scenario ~ geography, labeller = labeller(geography = c(square = "Part 1: square", queenstown = "Part 2: Queenstown"),
                                                       scenario = c(reference = "Reference (R3)", open_boundary = "Outside exposure (O3)"))) +
  scale_colour_manual(values = c(A = "gray40", B = "#0072B2", C = "#E69F00"),
                      labels = c(A = "A: existing vaccination only", B = "B: broad allocation", C = "C: older adults first"), name = NULL) +
  labs(x = "Model day", y = "Infectious individuals (median of epidemics)") + theme_bw(base_size = 9) + theme(legend.position = "bottom")
ggsave(file.path(fdir, "fig_ext_curves.png"), g_c, width = 8, height = 5.5, dpi = 200)
cat("extension analysis complete:", nrow(summ), "arm runs\n")
