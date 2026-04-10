# build/prepare_change_data.R
#
# Prepares county-level heating fuel change data for docs/change.html.
#
# Outputs
#   docs/data/change.json          — county-level percentage-point change (2024 - 2010)
#   docs/data/counties.geojson     — simplified county boundaries (cb=TRUE, ~400KB)
#
# Connecticut: ACS 2024 uses planning-region GEOIDs (09110–09190);
# ACS 2010 uses old 8-county GEOIDs (09001–09015). These cannot be matched
# at the sub-state level, so CT is aggregated to the state level and represented
# as a single polygon (union of 2020 TIGER county boundaries for CT).
#
# AK and HI excluded (consistent with main map).
#
# Dependencies: tidycensus, dplyr, sf, tigris, jsonlite, rmapshaper, geojsonsf

setwd("/Users/noahrauschkolb/Documents/Claude/Heating Fuel Mapping")
cat("Working directory:", getwd(), "\n")

library(tidycensus); library(purrr); library(dplyr)
library(sf);         library(tigris)
library(jsonlite);   library(rmapshaper)
options(tigris_use_cache = TRUE)

census_api_key("5508d1e16cef622a4033a524085b7117515a9e72")

CONUS <- setdiff(c(state.abb, "DC"), c("AK", "HI"))

ACS_VARS <- c(tot  = "B25040_001",
              gas  = "B25040_002",
              elec = "B25040_004",
              fo   = "B25040_005")

# ── 1. Pull county-level ACS data for 2010 and 2024 ──────────────────────────
pull_county_acs <- function(year) {
  cache <- sprintf("build/cache/county_acs_%d.rds", year)
  if (file.exists(cache)) {
    cat(sprintf("  [cache] county ACS %d\n", year))
    return(readRDS(cache))
  }
  cat(sprintf("  [pull]  county ACS %d ...\n", year))
  raw <- map_dfr(CONUS, function(s) {
    get_acs(geography = "county", variables = ACS_VARS,
            state = s, year = year, survey = "acs5", output = "wide")
  })
  df <- raw |>
    transmute(
      county_geoid = GEOID,
      county_name  = NAME,
      state_fips   = substr(GEOID, 1, 2),
      tot_hh       = totE,
      gas_hh       = gasE,
      elec_hh      = elecE,
      fo_hh        = foE,
      other_hh     = pmax(0L, tot_hh - gas_hh - elec_hh - fo_hh)
    ) |>
    filter(!is.na(tot_hh), tot_hh > 0) |>
    mutate(
      pct_gas   = gas_hh   / tot_hh,
      pct_elec  = elec_hh  / tot_hh,
      pct_fo    = fo_hh    / tot_hh,
      pct_other = other_hh / tot_hh
    )
  saveRDS(df, cache)
  df
}

cat("── Pulling county ACS data ──────────────────────────────────────────────\n")
df10 <- pull_county_acs(2010)
df24 <- pull_county_acs(2024)

cat(sprintf("2010: %d counties | 2024: %d counties\n", nrow(df10), nrow(df24)))

# ── 2. Aggregate CT to state level ───────────────────────────────────────────
# CT FIPS = "09". 2010 has 8 counties; 2024 has 9 planning regions.
# Both get aggregated to a single "09000" pseudo-GEOID representing Connecticut.
aggregate_ct_to_state <- function(df) {
  ct <- df |>
    filter(state_fips == "09") |>
    summarise(
      county_geoid = "09000",
      county_name  = "Connecticut",
      state_fips   = "09",
      tot_hh       = sum(tot_hh),
      gas_hh       = sum(gas_hh),
      elec_hh      = sum(elec_hh),
      fo_hh        = sum(fo_hh),
      other_hh     = sum(other_hh)
    ) |>
    mutate(
      pct_gas   = gas_hh   / tot_hh,
      pct_elec  = elec_hh  / tot_hh,
      pct_fo    = fo_hh    / tot_hh,
      pct_other = other_hh / tot_hh
    )
  bind_rows(filter(df, state_fips != "09"), ct)
}

df10_adj <- aggregate_ct_to_state(df10)
df24_adj <- aggregate_ct_to_state(df24)

cat(sprintf("After CT aggregation — 2010: %d | 2024: %d\n",
            nrow(df10_adj), nrow(df24_adj)))

# ── 3. Compute percentage-point changes ──────────────────────────────────────
# Join on adjusted GEOID. Only keep GEOIDs present in both years.
change <- inner_join(
  df10_adj |> select(county_geoid, county_name,
                     g10 = pct_gas, e10 = pct_elec, f10 = pct_fo, o10 = pct_other,
                     n10 = tot_hh),
  df24_adj |> select(county_geoid,
                     g24 = pct_gas, e24 = pct_elec, f24 = pct_fo, o24 = pct_other,
                     n24 = tot_hh),
  by = "county_geoid"
) |>
  mutate(
    dg = round(g24 - g10, 4),   # pp change, natural gas
    de = round(e24 - e10, 4),   # pp change, electricity
    df = round(f24 - f10, 4),   # pp change, fuel oil
    do = round(o24 - o10, 4)    # pp change, other/none
  )

cat(sprintf("Matched counties: %d\n", nrow(change)))
cat("Gas change range:   [", round(min(change$dg), 3), ",", round(max(change$dg), 3), "]\n")
cat("Elec change range:  [", round(min(change$de), 3), ",", round(max(change$de), 3), "]\n")
cat("FuelOil change range:[", round(min(change$df), 3), ",", round(max(change$df), 3), "]\n")
cat("Other change range:  [", round(min(change$do), 3), ",", round(max(change$do), 3), "]\n")

# ── 4. County geometries ──────────────────────────────────────────────────────
# Use 2020 TIGER cb=TRUE (cartographic, already simplified ~1:500k).
# For CT: dissolve all CT counties into a single polygon.
# AK/HI already excluded by CONUS list.
geojson_path <- "docs/data/counties.geojson"

if (!file.exists(geojson_path)) {
  cat("── Downloading county shapefiles ────────────────────────────────────────\n")
  sf_counties <- map_dfr(CONUS, function(s) {
    cat(" ", s)
    counties(state = s, year = 2020, cb = TRUE)
  })
  cat("\n")
  sf_counties <- st_transform(sf_counties, 4326)

  # Normalize GEOID column
  if (!"GEOID" %in% names(sf_counties) && "GEOID20" %in% names(sf_counties)) {
    sf_counties <- rename(sf_counties, GEOID = GEOID20)
  }

  # Dissolve CT counties → single polygon with pseudo-GEOID "09000"
  sf_ct <- sf_counties |>
    filter(substr(GEOID, 1, 2) == "09") |>
    summarise(GEOID = "09000", geometry = st_union(geometry))

  sf_non_ct <- sf_counties |>
    filter(substr(GEOID, 1, 2) != "09") |>
    select(GEOID)

  sf_final <- bind_rows(sf_non_ct, sf_ct)

  # Additional simplification to reduce file size (cb=TRUE is already ~1:500k)
  sf_final <- ms_simplify(sf_final, keep = 0.4, keep_shapes = TRUE)

  cat(sprintf("Writing %s (%d features)...\n", geojson_path, nrow(sf_final)))
  st_write(sf_final, geojson_path, quiet = TRUE, delete_dsn = TRUE)
  cat(sprintf("GeoJSON size: %.1f MB\n",
              file.size(geojson_path) / 1e6))
} else {
  cat(sprintf("  [exists] %s\n", geojson_path))
}

# ── 5. Write change.json ──────────────────────────────────────────────────────
change_path <- "docs/data/change.json"

if (!file.exists(change_path)) {
  cat(sprintf("── Writing %s (%d counties) ─────────────────────────\n",
              change_path, nrow(change)))

  records <- change |>
    rowwise() |>
    mutate(record = list(list(
      name = county_name,
      dg   = dg,   de  = de,   df  = df,   do  = do,
      g10  = round(g10, 4), e10 = round(e10, 4),
      f10  = round(f10, 4), o10 = round(o10, 4),
      g24  = round(g24, 4), e24 = round(e24, 4),
      f24  = round(f24, 4), o24 = round(o24, 4),
      n10  = n10,  n24 = n24
    ))) |>
    ungroup()

  out <- c(
    list(meta = list(
      year_start  = 2010,
      year_end    = 2024,
      n_counties  = nrow(change),
      ranges = list(
        gas   = list(min = round(min(change$dg), 3), max = round(max(change$dg), 3)),
        elec  = list(min = round(min(change$de), 3), max = round(max(change$de), 3)),
        fo    = list(min = round(min(change$df), 3), max = round(max(change$df), 3)),
        other = list(min = round(min(change$do), 3), max = round(max(change$do), 3))
      )
    )),
    setNames(records$record, records$county_geoid)
  )

  write(toJSON(out, auto_unbox = TRUE, digits = 4), change_path)
  cat(sprintf("Wrote %s (%.1f MB)\n", change_path,
              file.size(change_path) / 1e6))
} else {
  cat(sprintf("  [exists] %s\n", change_path))
}

cat("\n── Done. Open docs/change.html to view the change map. ─────────────────\n")
