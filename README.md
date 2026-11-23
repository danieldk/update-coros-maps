# COROS map rebuild from OpenStreetMap

**Warning:** Use at your own risk! In no event shall the authors or
copyright holders be liable for any claim, damages or other
liability.

Rebuilds the COROS landscape map files (`europe-landscape/map/VSM/...`) from a
fresh OpenStreetMap extract, producing drop-in replacements for the files
downloaded from coros.com. The topo map (`europe-topo/map/VCM/...`) is copied
unchanged (elevation/contour data is static).

Only tested with version 5.0.3 of the COROS Nomad maps.

## What it produces

- A full map tree with the same layout as the COROS download, with every VSM
  cell file rebuilt from current OSM data.
- A `delta/` directory next to the output containing only the rebuilt cells,
  for fast incremental copies to the watch (only changed files transfer).

Each rebuilt `.t` file is a PMTiles v3 archive identical in structure to the
original: same header (bounds, zoom z8–13, clustered layout), same metadata
block, a complete tile pyramid per cell including empty tiles, and the custom
per-tile trailer the watch expects. Tile content is gzip-compressed MVT with
the same layer names (`A`–`P`) and attribute schema (`E`, `X`, ...) as the
originals, with category codes derived from the original files.

## Requirements

- `tilemaker` — use a recent master build (much faster than releases):
  https://github.com/systemed/tilemaker
- `osmium` (osmium-tool)
- `python3` with `pmtiles` and `mapbox-vector-tile` (`pip3 install pmtiles mapbox-vector-tile`)
- ~40 GB free disk for the OSM extract + intermediates, plus output size

## Usage

```sh
./rebuild.sh <src_maps_dir> <out_dir> [work_dir] [tilemaker_bin] [osmium_bin]
```

Example:

```sh
JOBS=8 ./rebuild.sh ~/project/coros-maps ~/output/europe-full ~/output/work \
    "$HOME/git/tilemaker/tilemaker" "$(command -v osmium)"
```

- `<src_maps_dir>` — the unzipped COROS download (contains `europe-landscape/`
  and `europe-topo/`). The region/cell grid is derived from the original
  file headers.
- `<out_dir>` — where the rebuilt tree is written. `delta/` is created next to it.
- `[work_dir]` — scratch space (default: `<out_dir>/../work`). The
  `europe-latest.osm.pbf` download (~35 GB) is kept here and reused.
- `[tilemaker_bin]` — default `$TILEMAKER`, else `$HOME/git/tilemaker/tilemaker`.
- `[osmium_bin]` — default `$OSMIUM`, else `osmium` from PATH.

Environment: `JOBS` (parallel workers, default 8), `TILEMAKER`, `OSMIUM`.

## How it works

1. Downloads `europe-latest.osm.pbf` from Geofabrik (daily updates) if absent.
2. Reads the region/cell grid and bounding boxes from the original `.t` headers.
3. Phase 1: per region, one `osmium extract` + one `tilemaker` run
   (`config.json` + `process.lua` map OSM tags onto the COROS layer schema,
   zoom z8–13) → region PMTiles.
4. Phase 2: per original cell file, `repack.py` splits the region PMTiles into
   the cell's exact file (full pyramid, original header/metadata, per-tile
   trailer added by `coros_tile.py`).
5. Phase 3: installs rebuilt cells into the output tree and the delta dir.

Completed stages are skipped when outputs are newer than inputs, so the
script is safe to interrupt and re-run. To refresh the maps later, just re-run
it — or put it on a monthly cron.

## Installing on the watch

Copy the output tree (or just `delta/`) onto the watch's map storage in place
of the original `europe-landscape`/`europe-topo` folders, keeping the same
relative paths (`map/VSM/<region>/<cell>.t`).
