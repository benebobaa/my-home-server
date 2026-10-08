#!/usr/bin/env bash
# Loop-mount an NTFS partition image read-only and rsync everything except
# system files, recycle bins and code-project caches (node_modules, .gradle,
# .dart_tool, build/ next to a project manifest). See docs/runbooks/disk-rescue.md.
# usage: ntfs-extract.sh <image> <dest> [extra rsync excludes file]
set -eu
img=$1; dest=$2; extra=${3:-}
mnt=/mnt/img-$(basename "$img" .img); mkdir -p "$mnt" "$dest"
mountpoint -q "$mnt" || mount -t ntfs3 -o ro,loop "$img" "$mnt"
ex=$(mktemp)
cat > "$ex" <<'X'
/$RECYCLE.BIN/
/$Recycle.Bin/
/System Volume Information/
/hiberfil.sys
/pagefile.sys
/swapfile.sys
node_modules/
.gradle/
.dart_tool/
.pub-cache/
X
# build output dirs of code projects (sibling of a project manifest)
( cd "$mnt" && find . -type d -name build 2>/dev/null | while read -r d; do
    p=$(dirname "$d")
    for m in pubspec.yaml package.json build.gradle build.gradle.kts gradlew CMakeLists.txt; do
      [ -e "$p/$m" ] && { echo "/${d#./}/"; break; }
    done
  done ) >> "$ex" || true
[ -n "$extra" ] && cat "$extra" >> "$ex"
echo "excludes: $(wc -l < "$ex")"
rsync -rlt --exclude-from="$ex" --info=stats1 "$mnt"/ "$dest"/ 2>&1 | tail -6
cp "$ex" "$dest.excludes"
umount "$mnt"; rmdir "$mnt"
du -sh "$dest"; find "$dest" -type f | wc -l
