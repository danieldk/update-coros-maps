#!/bin/bash
# split-cell.sh <script_dir> <work_dir> <reg> <file> <orig> <dst>
# Split a region PMTiles into one COROS cell file (full pyramid, original
# header/metadata, COROS tile trailer). Skips if dst is up to date.
set -euo pipefail
HERE="$1"; WORK="$2"; reg="$3"; file="$4"; orig="$5"; dst="$6"
pm="$WORK/region-$reg.pmtiles"
if [ -f "$dst" ] && [ "$pm" -ot "$dst" ]; then
  echo "OK $file"
  exit 0
fi
mkdir -p "$(dirname "$dst")"
python3 "$HERE/repack.py" "$pm" "$orig" "$dst" > "$WORK/work-$file.log" 2>&1
echo "OK $file"
