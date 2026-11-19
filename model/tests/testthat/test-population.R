test_that("synthetic world meets the prespecified fit threshold", {
  w <- fixture_world()$world
  expect_true(all(w$fit$sae < 0.10))
  expect_equal(nrow(w$fit), 3)
})

test_that("structural zeros of the household structure table are reproduced", {
  cells <- fixture_world()$world$fit_cells |> dplyr::filter(table == "ss", target == 0)
  expect_true(all(cells$observed == 0))
})

test_that("households, roles and domestic workers are valid", {
  w <- fixture_world()$world; pp <- w$people; hh <- w$households
  expect_equal(length(unique(pp$person_id)), nrow(pp))
  expect_true(all(table(pp$hh_id)[as.character(hh$hh_id)] == hh$occupants))
  # One domestic worker per employing household; female, aged 23 to 60.
  fdw <- pp |> dplyr::filter(fdw)
  expect_true(all(fdw$sex == "F" & fdw$age >= 23 & fdw$age <= 60))
  expect_equal(sum(fdw$fdw), sum(hh$has_fdw))
  expect_equal(mean(hh$has_fdw), 0.158, tolerance = 0.01)
  expect_false(any(fdw$resident))
  # Spouses are reciprocal and of opposite sex.
  sp <- pp |> dplyr::filter(!is.na(spouse_id))
  partner <- pp[match(sp$spouse_id, pp$person_id), ]
  expect_true(all(partner$spouse_id == sp$person_id))
  expect_true(all(partner$sex != sp$sex))
  expect_true(all(partner$hh_id == sp$hh_id))
  # Parents are older than their children by at least 15 years.
  ch <- pp |> dplyr::filter(!is.na(parent_id))
  par <- pp[match(ch$parent_id, pp$person_id), ]
  expect_true(all(par$age - ch$age >= 15))
  # Floor area per occupant is positive and finite.
  expect_true(all(is.finite(hh$area_per_occupant) & hh$area_per_occupant > 0))
})

test_that("individuals and destinations stay inside the bounded area", {
  w <- fixture_world()$world; b <- w$settings_params$box
  for (pos in list(individual_positions(w, FALSE), individual_positions(w, TRUE))) {
    expect_true(all(pos$x > 0 & pos$x < b & pos$y > 0 & pos$y < b))
  }
})
