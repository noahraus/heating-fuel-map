#!/usr/bin/env bash
# build/build_tiles.sh
#
# Converts TIGER/Line GeoJSON exported by prepare_data.R into PMTiles archives
# using tippecanoe. Run from the repo root.
#
# Usage: bash build/build_tiles.sh
#
# Outputs:
#   docs/tiles/tracts_2010.pmtiles
#   docs/tiles/tracts_2020.pmtiles
#
# Zoom levels:
#   z2–z12  — enough to render tract boundaries at neighborhood level
#   tippecanoe simplifies automatically per zoom; no pre-simplification needed.
#
# --promote-id GEOID  — sets each feature's id = GEOID so MapLibre
#                       setFeatureState() can join to docs/data/{year}.json

set -euo pipefail
cd "$(dirname "$0")/.."   # run from repo root

TIPPECANOE=$(which tippecanoe) || { echo "tippecanoe not found in PATH"; exit 1; }
echo "Using tippecanoe: $TIPPECANOE ($($TIPPECANOE --version 2>&1 | head -1))"

mkdir -p docs/tiles

build_pmtiles() {
  local VINTAGE=$1
  local SRC="build/geojson/tracts_${VINTAGE}.geojson"
  local DST="docs/tiles/tracts_${VINTAGE}.pmtiles"

  if [ ! -f "$SRC" ]; then
    echo "ERROR: $SRC not found. Run build/prepare_data.R first."
    exit 1
  fi

  echo ""
  echo "── Building $DST ────────────────────────────────"
  echo "   Input:  $SRC ($(du -h "$SRC" | cut -f1))"

  # --use-attribute-for-id is avoided because tippecanoe converts string IDs
  # to integers, which would drop leading zeros from FIPS codes (e.g. "01001…").
  # Instead, GEOID is kept as a tile property and MapLibre's promoteId option
  # promotes it to the feature ID client-side, preserving the string value.
  "$TIPPECANOE" \
    --output="$DST" \
    --force \
    --layer=tracts \
    --minimum-zoom=2 \
    --maximum-zoom=12 \
    --coalesce-densest-as-needed \
    --extend-zooms-if-still-dropping \
    --no-tile-size-limit \
    --quiet \
    "$SRC"

  echo "   Output: $DST ($(du -h "$DST" | cut -f1))"
}

build_pmtiles 2010
build_pmtiles 2020

echo ""
echo "── Done ─────────────────────────────────────────"
echo "Tile files:"
du -h docs/tiles/*.pmtiles
