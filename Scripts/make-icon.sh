#!/bin/bash
# make-icon.sh -- builds build/AppIcon.icns from Scripts/make-icon.py output (macOS only: sips + iconutil).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
mkdir -p build
python3 Scripts/make-icon.py build/AppIcon-1024.png
set_dir=build/AppIcon.iconset
rm -rf "${set_dir:?}"; mkdir -p "$set_dir"
for s in 16 32 128 256 512; do
  sips -z $s $s build/AppIcon-1024.png --out "$set_dir/icon_${s}x${s}.png" >/dev/null
  d=$((s*2)); sips -z $d $d build/AppIcon-1024.png --out "$set_dir/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$set_dir" -o build/AppIcon.icns
echo "wrote build/AppIcon.icns (build-app.sh will bundle it)"
