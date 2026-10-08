#!/usr/bin/env bash
# Re-encode Zoom/Game Bar captures (1376x776@60, ~5.4 Mbps) to 30 fps H.264 on
# the Intel iGPU (VAAPI, full hardware decode+encode). Shared work queue:
# a file is claimed by mkdir of <out>/.claims/<name> (atomic, also over sshfs).
# usage: encode-worker.sh <src_dir> <out_dir> <render_node> <worker_name>
set -u
src=$1; out=$2; dev=$3; me=$4
mkdir -p "$out/.claims"
log="$out/.log-$me"
find "$src" -maxdepth 1 -type f -iname '*.mp4' -printf '%s\t%f\n' | sort -rn | cut -f2 |
while IFS= read -r f; do
  [ -e "$out/$f" ] && continue
  mkdir "$out/.claims/$f" 2>/dev/null || continue
  t0=$(date +%s)
  nice -n 10 ffmpeg -nostdin -v error -y -hwaccel vaapi -hwaccel_device "$dev" -hwaccel_output_format vaapi \
    -i "$src/$f" -vf fps=30 -c:v h264_vaapi -low_power 1 -rc_mode CQP -qp 27 -c:a copy \
    -movflags +faststart -f mp4 "$out/$f.part" 2>>"$log.err"
  rc=$?
  d_in=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$src/$f")
  d_out=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$out/$f.part" 2>/dev/null || echo 0)
  ok=$(awk -v a="$d_in" -v b="$d_out" 'BEGIN{d=a-b; if(d<0)d=-d; print (a>0 && d<=2)?1:0}')
  if [ $rc -eq 0 ] && [ "$ok" = 1 ]; then
    touch -r "$src/$f" "$out/$f.part" && mv "$out/$f.part" "$out/$f"
    printf '%s\tOK\t%ss\tin=%s\tout=%s\t%s\n' "$(date +%T)" $(( $(date +%s)-t0 )) "$d_in" "$d_out" "$f" >> "$log"
  else
    printf '%s\tFAIL\trc=%s\tin=%s\tout=%s\t%s\n' "$(date +%T)" "$rc" "$d_in" "$d_out" "$f" >> "$log"
  fi
done
echo "$(date +%T) worker $me finished" >> "$log"
