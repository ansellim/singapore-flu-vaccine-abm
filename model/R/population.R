# Synthetic population: sample-free reconstruction of households from role
# templates, followed by selection of whole households by simulated annealing
# against Census 2020 targets.
#
# Every number used here is either read from a stored public table
# (data_inputs.R) or declared in default_population_params() with its basis.

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(purrr)
})

# ---------------------------------------------------------------------------
# Parameters (each labeled observed, derived or assumed in the documentation)
# ---------------------------------------------------------------------------

default_population_params <- function() {
  list(
    target_residents = 5000,
    # Residents per household: D3 reports 4,402,305 persons in 1,366,891
    # households (3.221, including domestic workers); subtracting 0.158 domestic
    # workers per household gives 3.063 residents (derived).
    residents_per_household = 4402305 / 1366891 - 0.158,
    # Open 8+ size class: resident counts 8 to 11 with these weights give a class
    # mean of 8.65 against the published 8.665 (assumed shape, derived mean).
    size8_weights = c(`8` = 0.55, `9` = 0.30, `10` = 0.10, `11` = 0.05),
    # Domestic workers (Section 3).
    fdw_household_share = 0.158,                 # observed, SingStat C030030, 2020
    p_fdw_severe = 0.49,                         # observed in SSIC, Ansah 2016 Table 1
    p_fdw_older = 0.12,                          # observed, De Roza 2026
    p_fdw_child_under6 = 0.25,                   # assumed (Kua 2020 upper bound 0.307)
    p_fdw_other = 0.12,                          # pool prior; overall share fitted to 0.158
    # Severe difficulty among residents 65+ by living arrangement, Census 2020
    # (D4 'Unable to perform/with a lot of difficulty' over category totals; derived).
    severe_rate = c(spouse = 28613 / 379406, child_no_spouse = 29568 / 131621,
                    neither = 11850 / 111874),
    # Domestic worker age bands (Subramaniam 2026 Table 2, lower bound shifted to
    # the work-permit minimum of 23; observed shares, assumed within-band uniform).
    fdw_age_bands = tibble(lo = c(23L, 30L, 40L, 50L), hi = c(29L, 39L, 49L, 60L),
                           p = c(0.169, 0.395, 0.356, 0.080)),
    # Family age gaps (assumed): mother to child, parent to grandparent.
    mother_child_gap = c(20L, 42L),
    lone_parent_female = 0.8,
    generation_gap = c(20L, 40L),
    # Pool and annealing settings.
    pool_per_cell = 400L,
    sa_iterations = 400000L,
    sa_t0 = 2,
    sa_t1 = 0.001,
    sae_threshold = 0.10
  )
}

age_band_5 <- function(age) pmin(as.integer(age %/% 5L), 18L)  # 0..18, 18 = 90+
band_label_5 <- function(b) ifelse(b == 18L, "90+", sprintf("%d-%d", 5L * b, 5L * b + 4L))
older_band <- function(age) {
  cut(age, c(65, 70, 75, 80, 85, Inf), right = FALSE,
      labels = c("65-69", "70-74", "75-79", "80-84", "85+"))
}

# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------

build_targets <- function(inputs, pp, older_by_age) {
  H <- round(pp$target_residents / pp$residents_per_household)
  ss <- inputs$structure_size |>
    mutate(target = households / sum(households) * H)
  # Planning-area populations: households by size from the planning-area table
  # (pp$size_households, sizes "1".."8+"), with the national distribution of
  # household structure within each size.
  if (!is.null(pp$size_households)) {
    H <- round(sum(pp$size_households$households))
    ss <- inputs$structure_size |>
      group_by(size) |> mutate(p_struct = households / sum(households)) |> ungroup() |>
      mutate(target = p_struct * pp$size_households$households[match(as.character(size), pp$size_households$size)]) |>
      select(-p_struct)
    if (any(is.na(ss$target))) stop("size_households does not cover every household size")
  }
  as <- inputs$age_sex |>
    mutate(band = age_band_5(age_lo)) |>
    group_by(sex, band) |>
    summarise(count = sum(count), .groups = "drop") |>
    mutate(target = count / sum(count) * pp$target_residents)
  share65 <- sum(as$count[as$band >= 13L]) / sum(as$count)
  la <- older_by_age |>
    mutate(target = persons / sum(persons) * share65 * pp$target_residents)
  list(H = H, structure_size = ss, age_sex = as, older_living = la,
       fdw_households = pp$fdw_household_share * H,
       residents = pp$target_residents)
}

# Residents 65+ by living arrangement and age group, 2020 (SingStat M810821).
read_older_living_by_age <- function() {
  path <- file.path(evidence_dir(), "singstat-M810821-older-living-arrangement-age.json")
  side <- sub("\\.json$", ".source.json", path)
  meta <- jsonlite::fromJSON(side)
  if (!identical(digest::digest(file = path, algo = "sha256"), meta$sha256))
    stop("Checksum mismatch for M810821")
  rows <- jsonlite::fromJSON(path, simplifyVector = FALSE)$Data$row
  key <- c("Living With Spouse & At Least One Child In Household" = "spouse_child",
           "Living With Spouse, No Children In Household" = "spouse_no_child",
           "Living With Children But Without Spouse In Household" = "child_no_spouse",
           "Living In One-Person Household" = "alone",
           "Living With Only Domestic Worker(s) In Household" = "dw_only",
           "Others" = "other")
  ages <- c("65 - 69 Years" = "65-69", "70 - 74 Years" = "70-74", "75 - 79 Years" = "75-79",
            "80 - 84 Years" = "80-84", "85 Years & Over" = "85+")
  cur <- NA_character_; out <- list()
  for (r in rows) {
    txt <- r$rowText
    v <- NA_real_
    for (c in r$columns) if (identical(c$key, "2020")) v <- as.numeric(c$value)
    if (txt %in% names(ages)) { cur <- ages[[txt]]; next }
    if (txt == "Total") { cur <- "total"; next }
    if (txt %in% names(key) && cur != "total")
      out[[length(out) + 1]] <- tibble(age_group = cur, arrangement = key[[txt]], persons = v)
  }
  res <- bind_rows(out)
  if (nrow(res) != 30 || anyNA(res$persons)) stop("M810821 parse failed")
  res
}

# ---------------------------------------------------------------------------
# Household templates
# ---------------------------------------------------------------------------

# Draw a couple's ages from the Census joint distribution of wife and husband
# age groups; within-band ages uniform (Below 30 taken as 20 to 29, 65+ as 65 to 90).
draw_couple <- function(couples) {
  i <- sample.int(nrow(couples), 1, prob = couples$couples)
  w <- couples$wife_lo[i]; h <- couples$husband_lo[i]
  band_draw <- function(lo) {
    if (lo == 20L) sample(20:29, 1) else if (lo == 65L) sample(65:90, 1) else sample(lo:(lo + 4L), 1)
  }
  c(husband = band_draw(h), wife = band_draw(w))
}

adult_age_prior <- function(age_sex, min_age = 20L) {
  # Single-year ages spread uniformly within 5-year bands of the resident table.
  a <- age_sex |> group_by(age_lo, age_hi) |> summarise(n = sum(count), .groups = "drop") |>
    filter(age_lo >= min_age)
  ages <- unlist(map2(a$age_lo, pmin(a$age_hi, 99L), seq))
  w <- unlist(map2(a$n, pmin(a$age_hi, 99L) - a$age_lo + 1L, ~ rep(.x / .y, .y)))
  list(age = ages, w = w)
}

draw_adult <- function(prior, lo = 20L, hi = 99L) {
  keep <- prior$age >= lo & prior$age <= hi
  prior$age[keep][sample.int(sum(keep), 1, prob = prior$w[keep])]
}

# Members are returned as a data frame with local index, sex, age, spouse and
# parent links (local indices), and generation (1 = oldest).
new_member <- function(sex, age, gen, spouse = NA_integer_, parent = NA_integer_) {
  data.frame(sex = sex, age = as.integer(age), gen = as.integer(gen),
             spouse = as.integer(spouse), parent = as.integer(parent))
}

add_children <- function(m, k, mother_idx, mother_age, gap, gen) {
  if (k <= 0) return(m)
  for (i in seq_len(k)) {
    a <- mother_age - sample(gap[1]:gap[2], 1)
    if (a < 0) a <- sample(0:2, 1)
    m <- rbind(m, new_member(sample(c("M", "F"), 1), a, gen, parent = mother_idx))
  }
  m
}

make_couple <- function(couples, gen, min_wife_age = 0L) {
  # Rejection sampling keeps the Census joint age distribution, conditional on
  # the older couple of a two-generation household being old enough to have an
  # adult child at least one generation gap younger.
  repeat {
    ag <- draw_couple(couples)
    if (ag[["wife"]] >= min_wife_age) break
  }
  rbind(new_member("M", ag[["husband"]], gen, spouse = 2L),
        new_member("F", ag[["wife"]], gen, spouse = 1L))
}

# Generate the residents of one household with a given family structure and
# resident count r. Returns NULL when the structure cannot hold r residents.
generate_residents <- function(structure, r, couples, prior, pp) {
  gap <- pp$mother_child_gap; ggap <- pp$generation_gap
  m <- switch(structure,
    one_person = {
      if (r != 1) return(NULL)
      new_member(sample(c("M", "F"), 1), draw_adult(prior, 20L), 1L)
    },
    no_nucleus_multi = {
      if (r < 2) return(NULL)
      if (runif(1) < 0.3) {
        # Older adults living together without a family nucleus (siblings, friends).
        ages <- vapply(seq_len(r), function(i) draw_adult(prior, 60L), numeric(1))
      } else {
        a1 <- draw_adult(prior, 20L)
        ages <- c(a1, pmax(18L, pmin(99L, a1 + sample(-10:10, r - 1, replace = TRUE))))
      }
      new_member(sample(c("M", "F"), r, replace = TRUE), ages, 1L)
    },
    nucleus1_gen1 = {
      if (r < 2) return(NULL)
      m <- make_couple(couples, 1L)
      if (r > 2) {
        a <- pmax(18L, pmin(99L, m$age[1] + sample(-8:8, r - 2, replace = TRUE)))
        m <- rbind(m, new_member(sample(c("M", "F"), r - 2, replace = TRUE), a, 1L))
      }
      m
    },
    nucleus1_gen2 = {
      if (r < 2) return(NULL)
      if (r >= 3 && runif(1) < 0.85) {
        m <- make_couple(couples, 1L)
        add_children(m, r - 2, 2L, m$age[2], gap, 2L)
      } else {
        sx <- if (runif(1) < pp$lone_parent_female) "F" else "M"
        m <- new_member(sx, draw_adult(prior, 25L, 90L), 1L)
        add_children(m, r - 1, 1L, m$age[1], gap, 2L)
      }
    },
    nucleus1_gen3plus = {
      if (r < 3) return(NULL)
      if (r >= 4 && runif(1) < 0.75) {
        m <- make_couple(couples, 2L)                       # parents, local 1-2
        gp_age <- min(100L, max(m$age) + sample(ggap[1]:ggap[2], 1))
        m <- rbind(m, new_member(sample(c("M", "F"), 1, prob = c(0.3, 0.7)), gp_age, 1L))
        m$parent[sample(1:2, 1)] <- 3L                     # one parent is the grandparent's child
        add_children(m, r - 3, 2L, m$age[2], gap, 3L)
      } else {
        m <- new_member("F", draw_adult(prior, 25L, 70L), 2L)
        gp_age <- min(100L, m$age[1] + sample(ggap[1]:ggap[2], 1))
        m <- rbind(m, new_member(sample(c("M", "F"), 1, prob = c(0.3, 0.7)), gp_age, 1L))
        m$parent[1] <- 2L
        add_children(m, r - 2, 1L, m$age[1], gap, 3L)
      }
    },
    nucleus2_gen12 = {
      if (r < 4) return(NULL)
      gp <- make_couple(couples, 1L, min_wife_age = 18L + pp$generation_gap[1])                         # older couple
      kid <- make_couple(couples, 2L)                        # adult child's couple
      # Keep the generations consistent: the child couple is younger by a generation gap.
      shift <- max(0L, max(kid$age) - (gp$age[2] - gap[1]))
      kid$age <- pmax(18L, kid$age - shift)
      kid$spouse <- c(4L, 3L)
      kid$parent <- c(2L, NA_integer_)
      m <- rbind(gp, kid)
      if (r > 4) m <- add_children(m, r - 4, 2L, m$age[2], gap, 2L)
      m
    },
    nucleus2_gen3plus = {
      if (r < 4) return(NULL)
      gp <- make_couple(couples, 1L, min_wife_age = 18L + pp$generation_gap[1])
      if (r >= 5 && runif(1) < 0.8) {
        par <- make_couple(couples, 2L)
        shift <- max(0L, max(par$age) - (gp$age[2] - gap[1]))
        par$age <- pmax(18L, par$age - shift)
        par$spouse <- c(4L, 3L); par$parent <- c(2L, NA_integer_)
        m <- rbind(gp, par)
        add_children(m, r - 4, 4L, m$age[4], gap, 3L)
      } else {
        par <- new_member("F", max(18L, gp$age[2] - sample(gap[1]:gap[2], 1)), 2L, parent = 2L)
        m <- rbind(gp, par)
        add_children(m, r - 3, 3L, m$age[3], gap, 3L)
      }
    },
    nucleus3plus = {
      if (r < 6) return(NULL)
      gp <- make_couple(couples, 1L, min_wife_age = 18L + pp$generation_gap[1])
      c1 <- make_couple(couples, 2L); c2 <- make_couple(couples, 2L)
      for (k in 1:2) {
        cc <- if (k == 1) c1 else c2
        shift <- max(0L, max(cc$age) - (gp$age[2] - gap[1]))
        cc$age <- pmax(18L, cc$age - shift)
        if (k == 1) c1 <- cc else c2 <- cc
      }
      c1$spouse <- c(4L, 3L); c1$parent <- c(2L, NA_integer_)
      c2$spouse <- c(6L, 5L); c2$parent <- c(NA_integer_, 2L)
      m <- rbind(gp, c1, c2)
      add_children(m, r - 6, 4L, m$age[4], gap, 3L)
    },
    stop("unknown structure ", structure))
  if (nrow(m) != r) stop("template produced ", nrow(m), " residents for r = ", r)
  m
}

# Living arrangement of each resident aged 65+ (SingStat M810821 categories).
older_arrangement <- function(m, has_fdw) {
  n <- nrow(m)
  out <- rep(NA_character_, n)
  for (i in which(m$age >= 65L)) {
    sp <- m$spouse[i]
    with_spouse <- !is.na(sp)
    own_child <- any(m$parent %in% c(i, if (with_spouse) sp))
    out[i] <- if (with_spouse && own_child) "spouse_child" else
      if (with_spouse) "spouse_no_child" else
      if (own_child) "child_no_spouse" else
      if (n == 1 && !has_fdw) "alone" else
      if (n == 1 && has_fdw) "dw_only" else "other"
  }
  out
}

# Probability that a household employs a live-in domestic worker (Section 3).
p_fdw <- function(m, severe, pp, dw_only_p) {
  if (nrow(m) == 1 && m$age[1] >= 65L) return(dw_only_p[[as.character(older_band(m$age[1]))]])
  if (any(severe)) return(pp$p_fdw_severe)
  if (any(m$age < 6L)) return(pp$p_fdw_child_under6)
  if (any(m$age >= 65L)) return(pp$p_fdw_older)
  pp$p_fdw_other
}

# ---------------------------------------------------------------------------
# Candidate pool
# ---------------------------------------------------------------------------

size_label <- function(n) ifelse(n >= 8L, "8+", as.character(n))

generate_pool <- function(inputs, pp, older_by_age) {
  couples <- inputs$couples |> filter(couples > 0)
  prior <- adult_age_prior(inputs$age_sex)
  # P(domestic worker | older adult with no co-resident family) by age group,
  # from the 2020 counts: dw_only / (alone + dw_only).
  ob <- older_by_age |> filter(arrangement %in% c("alone", "dw_only")) |>
    pivot_wider(names_from = arrangement, values_from = persons) |>
    mutate(p = dw_only / (alone + dw_only))
  dw_only_p <- setNames(ob$p, ob$age_group)
  cells <- inputs$structure_size |> filter(households > 0)
  hh <- list(); k <- 0L
  for (ci in seq_len(nrow(cells))) {
    s <- cells$structure[ci]; sz <- as.character(cells$size[ci])
    for (rep_i in seq_len(pp$pool_per_cell)) {
      # A candidate in published size n has n residents, or n - 1 residents and a
      # domestic worker; both variants are generated so the annealing can choose.
      n_total <- if (sz == "8+") as.integer(sample(names(pp$size8_weights), 1, prob = pp$size8_weights)) else as.integer(sz)
      for (with_fdw in c(FALSE, TRUE)) {
        r <- n_total - as.integer(with_fdw)
        if (r < 1) next
        # One resident plus a domestic worker is classified as 'no family nucleus'.
        s_res <- if (with_fdw && s == "no_nucleus_multi" && r == 1) "one_person" else s
        if (with_fdw && s == "one_person") next
        m <- generate_residents(s_res, r, couples, prior, pp)
        if (is.null(m)) next
        arr <- older_arrangement(m, with_fdw)
        severe <- rep(FALSE, nrow(m))
        old_i <- which(!is.na(arr))
        if (length(old_i)) {
          grp <- ifelse(arr[old_i] %in% c("spouse_child", "spouse_no_child"), "spouse",
                        ifelse(arr[old_i] == "child_no_spouse", "child_no_spouse", "neither"))
          severe[old_i] <- runif(length(old_i)) < unname(pp$severe_rate[grp])
        }
        p <- p_fdw(m, severe, pp, dw_only_p)
        k <- k + 1L
        hh[[k]] <- list(structure = s, size = sz, fdw = with_fdw,
                        prior_weight = if (with_fdw) p else 1 - p,
                        members = cbind(m, older_arrangement = arr, severe = severe))
      }
    }
  }
  hh
}

# ---------------------------------------------------------------------------
# Simulated annealing selection of whole households
# ---------------------------------------------------------------------------

pool_count_matrix <- function(pool, targets) {
  ss_key <- paste(targets$structure_size$structure, targets$structure_size$size)
  as_key <- paste(targets$age_sex$sex, targets$age_sex$band)
  la_key <- paste(targets$older_living$age_group, targets$older_living$arrangement)
  keys <- c(paste0("ss|", ss_key), paste0("as|", as_key), paste0("la|", la_key), "fdw", "res")
  C <- matrix(0, nrow = length(pool), ncol = length(keys), dimnames = list(NULL, keys))
  for (i in seq_along(pool)) {
    h <- pool[[i]]; m <- h$members
    C[i, paste0("ss|", h$structure, " ", h$size)] <- 1
    ak <- paste0("as|", m$sex, " ", age_band_5(m$age))
    for (a in ak) C[i, a] <- C[i, a] + 1
    old <- which(m$age >= 65L)
    if (length(old)) {
      lk <- paste0("la|", older_band(m$age[old]), " ", m$older_arrangement[old])
      for (a in lk) C[i, a] <- C[i, a] + 1
    }
    C[i, "fdw"] <- as.numeric(h$fdw)
    C[i, "res"] <- nrow(m)
  }
  tvec <- c(targets$structure_size$target, targets$age_sex$target,
            targets$older_living$target, targets$fdw_households, targets$residents)
  # Each table contributes equally to the objective regardless of its cell count.
  block <- c(rep("ss", nrow(targets$structure_size)), rep("as", nrow(targets$age_sex)),
             rep("la", nrow(targets$older_living)), "fdw", "res")
  w <- 1 / as.numeric(table(block)[block])
  list(C = C, target = tvec, w = w, block = block)
}

anneal_select <- function(pc, H, prior_weight, pp) {
  C <- pc$C; tg <- pc$target; w <- pc$w
  n_pool <- nrow(C)
  sel <- sample.int(n_pool, H, replace = TRUE, prob = prior_weight)
  tot <- colSums(C[sel, , drop = FALSE])
  obj_of <- function(x) sum(w * (x - tg)^2 / (tg + 1))
  cur <- obj_of(tot)
  iters <- pp$sa_iterations
  temps <- pp$sa_t0 * (pp$sa_t1 / pp$sa_t0)^(seq_len(iters) / iters)
  out_pos <- sample.int(H, iters, replace = TRUE)
  in_cand <- sample.int(n_pool, iters, replace = TRUE, prob = prior_weight)
  u <- runif(iters)
  for (it in seq_len(iters)) {
    p <- out_pos[it]; o <- sel[p]; ni <- in_cand[it]
    if (o == ni) next
    new_tot <- tot - C[o, ] + C[ni, ]
    nv <- obj_of(new_tot)
    if (nv <= cur || u[it] < exp((cur - nv) / temps[it])) {
      sel[p] <- ni; tot <- new_tot; cur <- nv
    }
  }
  list(selected = sel, totals = tot, objective = cur)
}

# Fit statistics per table: classification error (TAE/2),
# standardized absolute error (TAE / total) and share of cells off by > 5%.
fit_report <- function(totals, pc) {
  tibble(cell = names(totals), observed = as.numeric(totals), target = pc$target,
         table = pc$block) |>
    filter(table %in% c("ss", "as", "la")) |>
    group_by(table) |>
    summarise(tae = sum(abs(observed - target)),
              total = sum(target),
              sae = tae / total,
              ce = tae / 2,
              e5 = mean(abs(observed - target) > 0.05 * pmax(target, 1)),
              .groups = "drop")
}

# ---------------------------------------------------------------------------
# Floor area, people table, domestic workers
# ---------------------------------------------------------------------------

draw_floor_area <- function(size, fa) {
  bands <- fa$bands |> filter(size == !!size)
  b <- as.character(sample(bands$band, 1, prob = bands$households))
  rng <- switch(b, le60 = c(20, 60), `60_80` = c(60, 80), `80_100` = c(80, 100),
                `100_120` = c(100, 120), gt120 = c(120, 200))
  list(band = b, area = runif(1, rng[1], rng[2]))
}

draw_fdw_age <- function(pp) {
  b <- sample.int(nrow(pp$fdw_age_bands), 1, prob = pp$fdw_age_bands$p)
  sample(pp$fdw_age_bands$lo[b]:pp$fdw_age_bands$hi[b], 1)
}

assemble_people <- function(pool, sel, inputs, pp) {
  hh_rows <- vector("list", length(sel)); ppl <- vector("list", length(sel))
  pid <- 0L
  for (h in seq_along(sel)) {
    cand <- pool[[sel[h]]]
    m <- cand$members
    fa <- draw_floor_area(cand$size, inputs$floor_area)
    n_occ <- nrow(m) + as.integer(cand$fdw)
    hh_rows[[h]] <- tibble(hh_id = h, structure = cand$structure, size_class = cand$size,
                           occupants = n_occ, residents = nrow(m), has_fdw = cand$fdw,
                           floor_band = fa$band, floor_area = fa$area,
                           area_per_occupant = fa$area / n_occ)
    ids <- pid + seq_len(nrow(m))
    res <- tibble(person_id = ids, hh_id = h, resident = TRUE, fdw = FALSE,
                  sex = m$sex, age = m$age,
                  spouse_id = ifelse(is.na(m$spouse), NA_integer_, pid + m$spouse),
                  parent_id = ifelse(is.na(m$parent), NA_integer_, pid + m$parent),
                  older_arrangement = m$older_arrangement, severe_difficulty = m$severe)
    pid <- pid + nrow(m)
    if (cand$fdw) {
      pid <- pid + 1L
      res <- bind_rows(res, tibble(person_id = pid, hh_id = h, resident = FALSE, fdw = TRUE,
                                   sex = "F", age = draw_fdw_age(pp), spouse_id = NA_integer_,
                                   parent_id = NA_integer_, older_arrangement = NA_character_,
                                   severe_difficulty = FALSE))
    }
    ppl[[h]] <- res
  }
  list(households = bind_rows(hh_rows), people = bind_rows(ppl))
}

# ---------------------------------------------------------------------------
# Top level
# ---------------------------------------------------------------------------

synthesize_population <- function(inputs, seed, pp = default_population_params(),
                                  older_by_age = read_older_living_by_age()) {
  set.seed(seed, kind = "L'Ecuyer-CMRG")
  targets <- build_targets(inputs, pp, older_by_age)
  pool <- generate_pool(inputs, pp, older_by_age)
  pc <- pool_count_matrix(pool, targets)
  prior_w <- vapply(pool, function(h) h$prior_weight, numeric(1))
  # Candidates are drawn in proportion to their template prior and to their
  # size-structure cell's target share, so the starting point is near the tables.
  cell_w <- targets$structure_size$target[match(
    vapply(pool, function(h) paste(h$structure, h$size), ""),
    paste(targets$structure_size$structure, targets$structure_size$size))]
  cell_n <- table(vapply(pool, function(h) paste(h$structure, h$size), ""))
  cw <- cell_w / as.numeric(cell_n[vapply(pool, function(h) paste(h$structure, h$size), "")])
  pw <- pmax(prior_w, 1e-6) * cw
  sa <- anneal_select(pc, targets$H, pw, pp)
  fit <- fit_report(sa$totals, pc)
  pop <- assemble_people(pool, sa$selected, inputs, pp)
  pop$fit <- fit
  pop$accepted <- all(fit$sae < pp$sae_threshold)
  pop$fit_cells <- tibble(cell = colnames(pc$C), observed = as.numeric(sa$totals),
                          target = pc$target, table = pc$block)
  pop$seed <- seed
  pop$params <- pp
  pop
}
