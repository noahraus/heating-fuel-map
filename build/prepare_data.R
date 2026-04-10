# build/prepare_data.R
#
# Prepares all inputs for the PMTiles + MapLibre heating fuel map.
#
# Outputs
#   build/geojson/tracts_2010.geojson  — full-resolution 2010 TIGER/Line (input to tippecanoe)
#   build/geojson/tracts_2020.geojson  — full-resolution 2020 TIGER/Line (input to tippecanoe)
#   docs/data/{year}.json              — tract-level fuel shares for years 2010–2024
#
# ACS vintage mapping
#   ACS 5-year 2010–2020  →  2010 Census tract definitions
#   ACS 5-year 2021–2024  →  2020 Census tract definitions
#
# Caches (build/cache/)
#   acs_{year}.rds        — raw ACS pull per year (one file per year)
#   sf_2010_full.rds      — full-resolution 2010 CONUS tract geometries
#   sf_2020_full.rds      — full-resolution 2020 CONUS tract geometries
#
# Dependencies: tidycensus, purrr, dplyr, sf, tigris, jsonlite, viridisLite
#   install.packages(c("tidycensus","purrr","dplyr","sf","tigris","jsonlite","viridisLite"))

setwd("/Users/noahrauschkolb/Documents/Claude/Heating Fuel Mapping")
cat("Working directory:", getwd(), "\n")

library(tidycensus); library(purrr); library(dplyr)
library(sf);         library(tigris)
library(jsonlite);   library(viridisLite); library(leaflet)
options(tigris_use_cache = TRUE)

census_api_key("5508d1e16cef622a4033a524085b7117515a9e72")

CONUS <- setdiff(c(state.abb, "DC"), c("AK", "HI"))

ACS_VARS <- c(tot  = "B25040_001",
              gas  = "B25040_002",
              elec = "B25040_004",
              fo   = "B25040_005")

YEARS_2010_TRACTS <- c(2010)      # ACS 5-year using 2010 Census geography
YEARS_2020_TRACTS <- c(2024)      # ACS 5-year using 2020 Census geography

# Palettes — must match docs/index.html
pal_gas   <- colorNumeric(plasma(256,  begin=0.1, end=0.9), domain=c(0,1), na.color="#d0d0d0")
pal_elec  <- colorNumeric(viridis(256, begin=0.1, end=0.9), domain=c(0,1), na.color="#d0d0d0")
pal_fo    <- colorNumeric(inferno(256, begin=0.1, end=0.9), domain=c(0,1), na.color="#d0d0d0")
pal_other <- colorNumeric(mako(256,    begin=0.1, end=0.9), domain=c(0,1), na.color="#d0d0d0")

# ── 1. ACS data — one cached RDS per year ────────────────────────────────────
pull_acs_year <- function(year) {
  cache <- sprintf("build/cache/acs_%d.rds", year)
  if (file.exists(cache)) {
    cat(sprintf("  [cache] %d\n", year))
    return(readRDS(cache))
  }
  cat(sprintf("  [pull]  %d ...\n", year))
  raw <- map_dfr(CONUS, function(s) {
    get_acs(geography="tract", variables=ACS_VARS,
            state=s, year=year, survey="acs5", output="wide")
  })
  df <- raw |>
    transmute(
      tract_geoid = GEOID,
      tract_name  = NAME,
      tot_hh      = totE,
      gas_hh      = gasE,
      elec_hh     = elecE,
      fo_hh       = foE,
      other_hh    = pmax(0L, tot_hh - gas_hh - elec_hh - fo_hh)
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

cat("── Pulling ACS data ─────────────────────────────────────────────────────\n")
all_years <- c(YEARS_2010_TRACTS, YEARS_2020_TRACTS)
acs_by_year <- setNames(map(all_years, pull_acs_year), all_years)

# ── 2. Tract geometries — full resolution for tippecanoe ────────────────────
pull_tracts_full <- function(vintage, cache_path) {
  if (file.exists(cache_path)) {
    cat(sprintf("  [cache] %d tract geometries\n", vintage))
    return(readRDS(cache_path))
  }
  cat(sprintf("  [download] %d TIGER/Line tracts (full resolution) ...\n", vintage))
  sf_out <- map_dfr(CONUS, function(s) {
    cat(" ", s)
    # Connecticut special case: 2020 TIGER/Line uses old 8-county FIPS codes,
    # but ACS 2021+ uses the new 9-planning-region codes introduced in 2022.
    # Use 2022 TIGER/Line for CT when building the 2020-vintage tile set.
    tract_year <- if (vintage == 2020 && s == "CT") 2022L else vintage
    tracts(state=s, year=tract_year, cb=FALSE)
  })
  cat("\n")
  sf_out <- st_transform(sf_out, 4326)
  # Normalize GEOID column name — 2010 vintage uses GEOID10
  if ("GEOID10" %in% names(sf_out) && !"GEOID" %in% names(sf_out)) {
    sf_out <- dplyr::rename(sf_out, GEOID = GEOID10)
  }
  saveRDS(sf_out, cache_path)
  sf_out
}

cat("── Downloading tract shapefiles ─────────────────────────────────────────\n")
sf_2010 <- pull_tracts_full(2010, "build/cache/sf_2010_full.rds")
sf_2020 <- pull_tracts_full(2020, "build/cache/sf_2020_full.rds")
cat("2010 tracts:", nrow(sf_2010), "| 2020 tracts:", nrow(sf_2020), "\n")

# ── 3. Export GeoJSON for tippecanoe (geometry + GEOID only) ─────────────────
# tippecanoe needs only GEOID; it uses --promote-id to set feature IDs for
# setFeatureState joins in MapLibre. All data lives in the per-year JSON files.
cat("── Exporting GeoJSON for tippecanoe ─────────────────────────────────────\n")

export_geojson <- function(sf_obj, path) {
  if (file.exists(path)) {
    cat(sprintf("  [exists] %s\n", path))
    return(invisible(NULL))
  }
  cat(sprintf("  Writing %s ...\n", path))
  sf_obj |>
    select(GEOID) |>
    st_write(path, quiet=TRUE, delete_dsn=TRUE)
}

export_geojson(sf_2010, "build/geojson/tracts_2010.geojson")
export_geojson(sf_2020, "build/geojson/tracts_2020.geojson")
cat("GeoJSON sizes:",
    round(file.size("build/geojson/tracts_2010.geojson")/1e6, 1), "MB (2010),",
    round(file.size("build/geojson/tracts_2020.geojson")/1e6, 1), "MB (2020)\n")

# ── 4. Per-year data JSON ─────────────────────────────────────────────────────
# Format: { "GEOID": { g, e, f, o, n, cg, ce, cf, co }, meta: {...} }
#   g/e/f/o  = pct_gas/elec/fo/other (0–1, 4 sig figs)
#   n        = total occupied HHs
#   cg/ce/cf/co = pre-computed hex colors for each fuel

cat("── Writing per-year data JSON ───────────────────────────────────────────\n")

write_year_json <- function(year, df) {
  path <- sprintf("docs/data/%d.json", year)
  if (file.exists(path)) {
    cat(sprintf("  [exists] %s\n", path))
    return(invisible(NULL))
  }
  cat(sprintf("  Writing %s (%d tracts) ...\n", path, nrow(df)))

  vintage <- if (year %in% YEARS_2020_TRACTS) "2020" else "2010"

  # Build named list for toJSON — one entry per GEOID
  tract_list <- df |>
    mutate(
      cg = pal_gas(pct_gas),
      ce = pal_elec(pct_elec),
      cf = pal_fo(pct_fo),
      co = pal_other(pct_other)
    ) |>
    rowwise() |>
    mutate(record = list(list(
      g  = round(pct_gas,   4),
      e  = round(pct_elec,  4),
      f  = round(pct_fo,    4),
      o  = round(pct_other, 4),
      n  = tot_hh,
      nm = tract_name,
      cg = cg, ce = ce, cf = cf, co = co
    ))) |>
    ungroup()

  out <- c(
    list(meta = list(
      year    = year,
      vintage = vintage,
      total_hh = sum(df$tot_hh)
    )),
    setNames(tract_list$record, tract_list$tract_geoid)
  )

  write(toJSON(out, auto_unbox=TRUE, digits=4), path)
}

for (yr in all_years) {
  write_year_json(yr, acs_by_year[[as.character(yr)]])
}

# ── 5. Write manifest ─────────────────────────────────────────────────────────
manifest <- list(
  years           = all_years,
  vintage_2010    = YEARS_2010_TRACTS,
  vintage_2020    = YEARS_2020_TRACTS,
  default_year    = max(all_years)
)
# auto_unbox=FALSE ensures single-element vectors stay as JSON arrays,
# which is required for .includes() in the JS frontend.
write(toJSON(manifest, auto_unbox=FALSE), "docs/data/manifest.json")
cat("Wrote docs/data/manifest.json\n")

cat("\n── Done. Run build/build_tiles.sh to generate PMTiles. ─────────────────\n")
