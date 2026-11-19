# Build the full-scale worlds of Parts 1 and 2. For each population seed one
# population is synthesized to the Queenstown planning area's Census 2020
# residents (age and sex) and households (number and size), and then placed
# on both layouts: the synthetic square (Part 1) and Queenstown (Part 2). The
# two parts therefore share their populations and differ only in geography.
# Resumable. Usage: Rscript scripts/build_worlds_ext.R N [first_seed]
source("scripts/common.R")
args <- commandArgs(trailingOnly = TRUE)
N <- as.integer(args[1]); first <- if (length(args) > 1) as.integer(args[2]) else 1L
qt <- queenstown_inputs()
inp <- load_inputs()
inp$age_sex <- read_age_sex("Queenstown - Total")
pp <- default_population_params()
pp$target_residents <- sum(inp$age_sex$count)
pp$size_households <- qt$hh_size
dirs <- c(square = out_dir("worlds_square"), queenstown = out_dir("worlds_queenstown"))
path <- function(g, s) file.path(dirs[[g]], sprintf("world_%03d.rds", s))
todo <- Filter(function(s) !all(file.exists(c(path("square", s), path("queenstown", s)))), first:N)
cat("building", length(todo), "population seeds on", n_cores(), "cores\n")
res <- mclapply(todo, function(s) {
  tries <- 0L; seed <- s
  repeat {
    tries <- tries + 1L
    pop <- synthesize_population(inp, seed, pp)
    if (pop$accepted) break
    if (tries >= 5L) stop("no accepted population from seed ", s)
    seed <- seed + 100000L
  }
  fits <- list()
  for (g in c("square", "queenstown")) {
    set.seed(seed + if (g == "square") 1L else 2L, kind = "L'Ecuyer-CMRG")
    layout <- if (g == "square") square_layout_for(qt) else queenstown_layout(qt)
    world <- assign_settings_layout(pop, inp, layout)
    world$fit <- pop$fit; world$fit_cells <- pop$fit_cells
    world$cell_fit <- attr(world$households, "cell_fit")
    world$pop_seed <- s; world$accepted_seed <- seed; world$rejections <- tries - 1L
    save_atomic(world, path(g, s))
    cf <- world$cell_fit
    fits[[g]] <- bind_rows(world$fit, if (!is.null(cf)) tibble(table = paste0("qt_", names(cf)), sae = unname(cf))) |>
      mutate(geography = g, pop_seed = s, rejections = tries - 1L, residents = sum(world$people$resident),
             fdw = sum(world$people$fdw), households = nrow(world$households))
  }
  bind_rows(fits)
}, mc.cores = n_cores(), mc.preschedule = FALSE)
bad <- vapply(res, inherits, logical(1), "try-error")
if (any(bad)) stop("world building failed: ", paste(vapply(res[bad], as.character, ""), collapse = "\n"))
fits <- bind_rows(res)
readr::write_csv(fits, file.path(out_dir("summary"), sprintf("world_fit_ext_%s.csv", format(Sys.time(), "%H%M%S"))))
print(fits |> group_by(geography, table) |> summarise(max_sae = max(sae), mean_sae = mean(sae), .groups = "drop"))
