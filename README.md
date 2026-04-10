# US Heating Fuel by Census Tract

An interactive map showing the tract-level share of occupied housing units using each primary heating fuel across the contiguous United States, with a year slider covering ACS 5-year estimates from 2010 through 2024.

**[View the live map →](https://noahraus.github.io/heating-fuel-map/)**

![Four-panel synchronized choropleth map showing natural gas, electricity, fuel oil, and other heating fuel shares by census tract](https://noahraus.github.io/heating-fuel-map/preview.png)

---

## What it shows

Four synchronized choropleth panels, one for each fuel category:

| Panel | Fuel category | ACS variable |
|---|---|---|
| Natural Gas | Utility (piped) gas | B25040_002 |
| Electricity | All electric heating (resistance + heat pumps) | B25040_004 |
| Fuel Oil & Kerosene | Fuel oil, kerosene | B25040_005 |
| Other / No Fuel | Bottled gas, wood, solar, coal, other, none | B25040_001 minus above |

All four panels are synchronized — panning or zooming one moves all others. Hovering any tract shows all four fuel percentages plus the total occupied unit count.

---

## Data sources

### ACS Table B25040 — House Heating Fuel
- **Publisher:** U.S. Census Bureau
- **Survey:** American Community Survey (ACS) 5-year estimates
- **Years:** 2010–2024 (15 vintages)
- **Geography:** Census tracts, contiguous United States (49 states + DC; Alaska and Hawaii excluded)
- **Universe:** Occupied housing units
- **Access:** Pulled via the [`tidycensus`](https://walker-data.com/tidycensus/) R package using the [Census Data API](https://www.census.gov/data/developers/data-sets/acs-5year.html)

### Census tract boundaries
- **Publisher:** U.S. Census Bureau, TIGER/Line Shapefiles
- **Vintages:**
  - **2010 tracts** — used for ACS years 2010–2020
  - **2020 tracts** — used for ACS years 2021–2024
  - Connecticut exception: ACS 2021+ uses 2022 TIGER/Line for Connecticut because the state replaced its 8 counties with 9 planning regions as Census statistical geographies in 2022, changing all CT tract GEOIDs
- **Access:** Downloaded via the [`tigris`](https://github.com/walkerke/tigris) R package

---

## Architecture

```
build/
  prepare_data.R        # Pulls ACS data, exports GeoJSON and per-year JSONs
  build_tiles.sh        # Runs tippecanoe to generate PMTiles
  cache/                # Local cache (gitignored — regenerable)
  geojson/              # Intermediate full-res GeoJSON (gitignored)

docs/                   # Served by GitHub Pages
  index.html            # MapLibre GL JS frontend
  data/
    manifest.json       # Year list and vintage mapping
    2010.json           # Per-year tract data (GEOID → fuel shares + hex colors)
    2011.json
    ...
    2024.json

docs/tiles/             # Hosted on Cloudflare R2 (gitignored — too large for GitHub)
  tracts_2010.pmtiles   # ~128 MB
  tracts_2020.pmtiles   # ~144 MB
```

### Frontend
- **[MapLibre GL JS](https://maplibre.org/)** for rendering
- **[PMTiles](https://protomaps.com/docs/pmtiles)** for efficient vector tile delivery — the browser only fetches tile data covering the current viewport via HTTP range requests
- **[Cloudflare R2](https://developers.cloudflare.com/r2/)** for PMTiles hosting (free tier, zero egress fees)
- **[GitHub Pages](https://pages.github.com/)** for serving HTML and data JSONs

### Data flow
1. `prepare_data.R` pulls B25040 for all 49 states × 15 years from the Census API (results cached locally as RDS files)
2. It exports full-resolution TIGER/Line GeoJSON (geometry only, ~1 GB each) for tippecanoe input, and per-year JSON data files for the frontend
3. `build_tiles.sh` runs [tippecanoe](https://github.com/felt/tippecanoe) to produce PMTiles archives with zoom-level-appropriate simplification (z2–z12)
4. PMTiles are uploaded to Cloudflare R2; HTML + data JSONs are pushed to GitHub
5. The browser loads the page, fetches `manifest.json`, then loads the selected year's data JSON and applies colors via MapLibre `setFeatureState`

---

## Reproducing the build

### Prerequisites

```bash
brew install r tippecanoe
```

R packages:
```r
install.packages(c(
  "tidycensus", "purrr", "dplyr", "sf", "tigris",
  "rmapshaper", "geojsonsf", "jsonlite", "viridisLite", "leaflet"
))
```

You will also need a free [Census API key](https://api.census.gov/data/key_signup.html). Set it at the top of `build/prepare_data.R`.

### Steps

```bash
# 1. Pull ACS data and export GeoJSON + data JSONs
Rscript build/prepare_data.R

# 2. Build PMTiles (takes ~10 minutes per vintage)
bash build/build_tiles.sh

# 3. Upload docs/tiles/*.pmtiles to Cloudflare R2
#    (or any static host that supports HTTP range requests)

# 4. Set your R2 bucket URL in docs/index.html:
#    const TILES_BASE = "https://your-bucket.r2.dev";

# 5. Push docs/ to GitHub and enable Pages
git push
```

### Adding a new year

When a new ACS 5-year release is published:

1. Add the year to `YEARS_2020_TRACTS` in `build/prepare_data.R`
2. Run `Rscript build/prepare_data.R` — only the new year will be fetched (others are cached)
3. If the new year introduces a new tract vintage, rebuild tiles with `bash build/build_tiles.sh`
4. Push `docs/data/` to GitHub

---

## Notes on gray tracts

Tracts that appear gray (no color) have no ACS heating fuel data. This occurs in two cases:

- **Special tracts (98xx/99xx):** Water bodies, military reservations, and uninhabited federal land (e.g., the Nevada National Security Site). These are valid geographic features in TIGER/Line but have no occupied housing units.
- **Zero-HH tracts:** Airports, industrial zones, parks, and group-quarters-only areas that have no occupied housing units in the ACS estimate.

These are not missing data — they are tracts where the universe (occupied housing units) is zero.

---

## License

Data is from the U.S. Census Bureau and is in the public domain. Code in this repository is available under the MIT License.
