#!/bin/bash
# rebuild.sh -- rebuild COROS landscape (VSM) map files from fresh OpenStreetMap data.
#
# Usage:
#   ./rebuild.sh <src_maps_dir> <out_dir> [work_dir] [tilemaker_bin]
#
#   <src_maps_dir>  dir containing the unzipped COROS download, i.e. with
#                   europe-landscape/map/VSM/... and europe-topo/map/VCM/...
#   <out_dir>       where the rebuilt tree is written (same layout as src;
#                   europe-topo is copied unchanged, VSM cells are rebuilt)
#   [work_dir]      scratch dir for the OSM download + intermediates
#                   (default: <out_dir>/../work)
#   [tilemaker_bin] path to a native tilemaker binary (use a recent master
#                   build -- it is orders of magnitude faster than releases;
#                   default: $TILEMAKER or $HOME/git/tilemaker/tilemaker)
#   [osmium_bin]    full path to the osmium binary
#                   (default: $OSMIUM or "osmium" from PATH)
#
# Pipeline (two-phase, avoids rescanning big extracts per cell):
#   1. download europe-latest.osm.pbf from Geofabrik (skipped if present)
#   2. derive region/cell grid + bboxes from the ORIGINAL .t file headers
#   3. per region: osmium extract -> ONE tilemaker run -> region PMTiles
#      (config.json + process.lua reproduce the COROS layer schema:
#       layers A..P, attributes E/X/..., zoom z8-13)
#   4. per cell: repack.py splits the region PMTiles into the original cell
#      file layout (full z8-13 pyramid, original header/metadata, and the
#      custom COROS per-tile trailer added by coros_tile.py)
#   5. assemble <out_dir> = original tree with every VSM cell replaced, plus
#      <out_dir>/../delta/ containing only the rebuilt cells (fast copies)
#
# Requirements: python3 with `pmtiles` and `mapbox-vector-tile`
#   pip3 install pmtiles mapbox-vector-tile
#
# Re-run any time; Geofabrik updates daily. Completed stages are skipped
# (outputs newer than their inputs), so it is safe to interrupt and resume.
set -euo pipefail

SRC="${1:?usage: rebuild.sh <src_maps_dir> <out_dir> [work_dir] [tilemaker_bin] [osmium_bin]}"
OUT="${2:?usage: rebuild.sh <src_maps_dir> <out_dir> [work_dir] [tilemaker_bin] [osmium_bin]}"
WORK="${3:-$(dirname "$OUT")/work}"
TM="${4:-${TILEMAKER:-$HOME/git/tilemaker/tilemaker}}"
OSMIUM="${5:-${OSMIUM:-osmium}}"
HERE="$(cd "$(dirname "$0")" && pwd)"
JOBS="${JOBS:-8}"

mkdir -p "$WORK" "$WORK/out"
EUROPE_PBF="$WORK/europe-latest.osm.pbf"

echo "== deps"
"$OSMIUM" --version >/dev/null 2>&1 || { echo "missing osmium binary: $OSMIUM (pass full path as 5th arg or set \$OSMIUM)"; exit 1; }
python3 -c 'import pmtiles, mapbox_vector_tile' 2>/dev/null || { echo "missing: pip3 install pmtiles mapbox-vector-tile"; exit 1; }
[ -x "$TM" ] || { echo "missing tilemaker binary: $TM"; exit 1; }

echo "== download OSM extract (skipped if present)"
if [ ! -f "$EUROPE_PBF" ]; then
  curl -sL --continue-at - -o "$EUROPE_PBF" https://download.geofabrik.de/europe/europe-latest.osm.pbf
fi

echo "== derive region/cell grid from original files"
python3 - "$SRC" "$WORK" <<'PYEOF'
import glob, struct, json, sys, os
src, work = sys.argv[1], sys.argv[2]
regions, cells = {}, []
for p in sorted(glob.glob(os.path.join(src, 'europe-landscape/map/VSM/*/*.t'))):
    reg, name = p.split('/')[-2], p.split('/')[-1]
    with open(p, 'rb') as f:
        hdr = f.read(127)
    a, b, c, d = struct.unpack('<4i', hdr[102:118])
    bb = [a/1e7, b/1e7, c/1e7, d/1e7]
    r = regions.setdefault(reg, [999.0, 999.0, -999.0, -999.0])
    r[0] = min(r[0], bb[0]); r[1] = min(r[1], bb[1]); r[2] = max(r[2], bb[2]); r[3] = max(r[3], bb[3])
    cells.append({'region': reg, 'file': name, 'bbox': bb, 'orig': p})
json.dump(regions, open(os.path.join(work, 'regions.json'), 'w'))
json.dump(cells, open(os.path.join(work, 'cells.json'), 'w'))
print(len(cells), 'cells in', len(regions), 'regions')
PYEOF

echo "== assemble output tree (topo copied unchanged)"
if [ ! -d "$OUT/europe-topo" ]; then
  rm -rf "$OUT"
  mkdir -p "$OUT"
  cp -R "$SRC/europe-landscape" "$SRC/europe-topo" "$OUT/"
fi

echo "== phase 1: region extracts + region PMTiles"
python3 - "$WORK" <<'PYEOF' > "$WORK/region-jobs.txt"
import json, os
work = os.sys.argv[1]
regions = json.load(open(os.path.join(work, 'regions.json')))
for reg, bb in sorted(regions.items()):
    print('%s %.4f,%.4f,%.4f,%.4f' % (reg, bb[0], bb[1], bb[2], bb[3]))
PYEOF
cat "$WORK/region-jobs.txt" | xargs -P "$JOBS" -L 1 bash "$HERE/build-region.sh" "$TM" "$OSMIUM" "$HERE" "$WORK" "$EUROPE_PBF" > "$WORK/regions.log" 2>&1 || true
grep -c '^OK' "$WORK/regions.log" | xargs echo "regions done:"

echo "== phase 2: split region PMTiles into original cell files"
python3 - "$WORK" "$OUT" <<'PYEOF' > "$WORK/cell-jobs.txt"
import json, os
work, out = os.sys.argv[1], os.sys.argv[2]
cells = json.load(open(os.path.join(work, 'cells.json')))
for c in cells:
    dst = os.path.join(work, 'work-out', 'europe-landscape/map/VSM', c['region'], c['file'])
    print('%s %s %s %s' % (c['region'], c['file'], c['orig'], dst))
PYEOF
cat "$WORK/cell-jobs.txt" | xargs -P "$JOBS" -L 1 bash "$HERE/split-cell.sh" "$HERE" "$WORK" > "$WORK/cells.log" 2>&1 || true
echo "cells done: $(grep -c '^OK' "$WORK/cells.log") / $(grep -c . "$WORK/cell-jobs.txt")"

echo "== phase 3: install into output tree + delta"
find "$WORK/work-out" -name '*.t' | while read -r f; do
  rel="${f#$WORK/work-out/}"
  mkdir -p "$OUT/$(dirname "$rel")" "$(dirname "$OUT")/delta/$(dirname "$rel")"
  cp "$f" "$OUT/$rel"
  cp "$f" "$(dirname "$OUT")/delta/$rel"
done
echo "DONE. Rebuilt tree: $OUT   Incremental delta: $(dirname "$OUT")/delta"
