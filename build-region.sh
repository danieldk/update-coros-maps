#!/bin/bash
# build-region.sh <tilemaker_bin> <osmium_bin> <script_dir> <work_dir> <europe_pbf> <reg> <bbox>
# One osmium extract + one tilemaker run per region. (invoked by rebuild.sh)
set -euo pipefail
TM="$1"; OSMIUM="$2"; HERE="$3"; WORK="$4"; EUROPE="$5"; reg="$6"; bbox="$7"
ext="$WORK/extract-$reg.osm.pbf"
pm="$WORK/region-$reg.pmtiles"
if [ ! -f "$ext" ] || [ "$EUROPE" -nt "$ext" ]; then
  "$OSMIUM" extract --bbox="$bbox" "$EUROPE" -o "$ext" -f pbf --overwrite
fi
if [ ! -f "$pm" ] || [ "$ext" -nt "$pm" ]; then
  "$TM" --input "$ext" --output "$pm" \
        --config "$HERE/config.json" --process "$HERE/process.lua" --threads 8 \
        > "$WORK/region-$reg.log" 2>&1
fi
echo "OK $reg"
