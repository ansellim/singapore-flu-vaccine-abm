# Spatial figures: the synthetic community and infection-status snapshots at
# common times for one illustrative epidemic per arm (assignment requirement).
# These show one run and are illustrations, not summaries of the experiment.
# The epidemic shown is the one, among the 50 reference-scenario epidemics of
# this population and set, whose resident attack proportions in the three arms
# are jointly closest to the three arms' medians (sum of absolute deviations).
# Usage: Rscript scripts/figure_spatial.R <world number> <set>
source("scripts/common.R"); source("scripts/scenarios.R")
suppressPackageStartupMessages({ library(ggplot2); library(patchwork) })
args <- commandArgs(trailingOnly = TRUE)
wn <- as.integer(args[1]); set_name <- args[2]
st <- retained_sets()[retained_sets()$set == set_name, ]
tau <- st$tau; h <- st$h
chunk <- readRDS(file.path(out_dir("experiment"), sprintf("reference__%s__pop%03d.rds", set_name, wn)))
score <- chunk$summary |> group_by(arm) |> mutate(dev = abs(ap_residents - median(ap_residents))) |>
  group_by(epi_seed) |> summarise(dev = sum(dev), .groups = "drop")
seed <- score$epi_seed[which.min(score$dev)]
world <- readRDS(file.path(out_dir("worlds"), sprintf("world_%03d.rds", wn)))
mp <- default_model_params(); mp$tau <- tau; mp$h <- h
ep <- run_epidemic(world, contact_rates(world, load_prem_sgp()), mp, seed, record_infector = FALSE)
pp <- world$people
fdir <- out_dir("figures")
theme_set(theme_void(base_size = 9) +
            theme(plot.background = element_rect(fill = "white", colour = NA),
                  panel.background = element_rect(fill = "white", colour = NA),
                  panel.border = element_rect(fill = NA, colour = "grey60"),
                  plot.title = element_text(face = "bold", hjust = 0),
                  plot.title.position = "plot", plot.caption.position = "plot",
                  plot.caption = element_text(hjust = 0, colour = "grey30"),
                  strip.text = element_text(face = "bold", margin = margin(3, 3, 3, 3)),
                  plot.margin = margin(10, 12, 10, 12)))
km <- function(x) x / 1000

# Map of the community: households by neighborhood and setting locations.
hh <- world$households
sites <- world$sites |> mutate(kind = recode(type, primary = "Preschool and primary school site",
                                              secondary = "Secondary school site", tertiary = "Tertiary school site"))
# Same conventions as the full-scale maps (analyze_ext.R, Figure 2): households
# colored with the turbo palette, setting locations as black symbols.
nb_cols <- setNames(scales::viridis_pal(option = "turbo", begin = 0.1, end = 0.9)(4), 1:4)
m <- ggplot() +
  geom_point(data = hh, aes(km(x), km(y), colour = factor(neighborhood)), size = 0.6, alpha = 0.85) +
  geom_point(data = world$workplaces, aes(km(x), km(y), shape = "Workplace"), size = 0.9, colour = "grey25") +
  geom_point(data = world$venues, aes(km(x), km(y), shape = "Community venue"), size = 2, colour = "black") +
  geom_point(data = sites, aes(km(x), km(y), shape = kind), size = 3, colour = "black", fill = "white", stroke = 0.8) +
  geom_hline(yintercept = 2, colour = "grey40") + geom_vline(xintercept = 2, colour = "grey40") +
  scale_shape_manual(values = c("Community venue" = 17, "Preschool and primary school site" = 22,
                                "Secondary school site" = 23, "Tertiary school site" = 8, "Workplace" = 3),
                     name = "Settings") +
  scale_colour_manual(values = nb_cols, name = "Households, by neighborhood",
                      labels = paste("Neighborhood", 1:4)) +
  guides(colour = guide_legend(order = 1, override.aes = list(size = 2.5, alpha = 1)),
         shape = guide_legend(order = 2)) +
  annotate("segment", x = 0.2, xend = 1.2, y = 0.12, yend = 0.12, linewidth = 0.6) +
  annotate("label", x = 0.7, y = 0.27, label = "1 km", size = 3, linewidth = 0, fill = "white") +
  coord_equal(xlim = c(0, 4), ylim = c(0, 4), expand = FALSE) +
  theme(legend.title = element_text(face = "bold")) +
  labs(title = "Synthetic community (4 km x 4 km, four neighborhoods)",
       caption = sprintf("World %d: %d households, %d residents, %d live-in domestic workers. Each colored point is one household.\nCoordinates are synthetic, not Singapore addresses.",
                         wn, nrow(hh), sum(pp$resident), sum(pp$fdw)))
ggsave(file.path(fdir, "fig_community_map.png"), m, width = 6.5, height = 6, dpi = 200)

# Infection status at the start of selected days, at home locations.
status_at <- function(run, day) {
  t <- 2L * day
  inf <- run$inf_step
  s <- ifelse(run$initially_immune, "Immune at start", "S")
  infected <- !is.na(inf) & inf <= t
  s[infected & (t - inf) < mp$recovery_steps] <- "I"
  s[infected & (t - inf) >= mp$recovery_steps] <- "Recovered"
  s[s == "S" & !is.na(run$dose_day)] <- "S, campaign dose"
  s
}
days <- c(38, 50, 60, 75, 100)
snap <- bind_rows(lapply(names(ep$runs), function(a) bind_rows(lapply(days, function(d)
  tibble(arm = a, day = d, x = km(pp$home_x), y = km(pp$home_y), status = status_at(ep$runs[[a]], d))))))
# Household members share a home coordinate; a small jitter (up to 20 m)
# keeps them visible without moving anyone out of their neighborhood.
set.seed(1)
jx <- runif(nrow(pp), -0.02, 0.02); jy <- runif(nrow(pp), -0.02, 0.02)
snap <- snap |> mutate(x = x + rep(jx, length(days) * 3), y = y + rep(jy, length(days) * 3))
ap_arm <- vapply(ep$runs, function(r) mean(!is.na(r$inf_step[pp$resident])), numeric(1))
arm_lab <- c(A = "A: existing vaccination only", B = "B: broad allocation", C = "C: older adults first")
arm_lab <- sprintf("%s\n(%.1f%% of residents infected)", arm_lab[names(ap_arm)], 100 * ap_arm)
names(arm_lab) <- names(ap_arm)
snap <- snap |> mutate(status = factor(status, c("S", "S, campaign dose", "Immune at start", "Recovered", "I"),
                                       labels = c("S", "S, received a campaign dose", "R: immune at start",
                                                  "R: recovered after infection", "I (infected, including latent)")),
                       arm = factor(arm_lab[arm], arm_lab), day = paste("Day", day))
snap$day <- factor(snap$day, paste("Day", days))
p <- ggplot(snap |> arrange(status), aes(x, y, colour = status)) +
  geom_hline(yintercept = 2, colour = "grey50", linewidth = 0.3) +
  geom_vline(xintercept = 2, colour = "grey50", linewidth = 0.3) +
  geom_point(aes(size = status), alpha = 0.8) +
  facet_grid(arm ~ day) +
  scale_colour_manual(values = c("#D5DBE1", "#E69F00", "#C9B79C", "#002F6B", "#D7263D")) +
  scale_size_manual(values = c(0.25, 0.5, 0.25, 0.3, 0.6), guide = "none") +
  coord_equal(xlim = c(0, 4), ylim = c(0, 4), expand = FALSE) +
  guides(colour = guide_legend(override.aes = list(size = 2, alpha = 1))) +
  labs(colour = NULL, title = "Infection status at home locations, one illustrative epidemic",
       caption = sprintf(paste("Population %d, set %s (tau = %.2f, h = %.1f), epidemic seed %d: of the 50 reference-scenario epidemics of this population and set,",
                               "the one whose resident attack\nproportions in the three arms are jointly closest to the arms' medians. The same random numbers in every arm.",
                               "Points are individuals at their home locations (jittered up to 20 m); gray lines: neighborhood boundaries."),
                         wn, set_name, tau, h, seed)) +
  theme(legend.position = "bottom", strip.text.y = element_text(angle = 0, hjust = 0))
ggsave(file.path(fdir, "fig_spatial_snapshots.png"), p, width = 10, height = 6.8, dpi = 200)
cat("spatial figures written; epidemic seed", seed, "; attack proportions", round(100 * ap_arm, 2), "\n")
