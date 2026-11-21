#!/bin/bash
# Objective frame comparison, numbers only (no image is written to disk beyond the capture PPMs, which stay local).
# usage: frame-metrics.sh REP FRAME > frame-metrics.csv   (cells ..._r<REP> under frames/ppm, frame FRAME)
# PSNR in dB (120 = identical), DSSIM (ImageMagick, 0 = identical). Needs ImageMagick.
ROOT=$(cd "$(dirname "$0")/.." && pwd); F=$ROOT/frames; rep=${1:-c2}; fr=${2:-500}
sc() { local p d; p=$(magick compare -metric PSNR "$1" "$2" null: 2>&1 | awk '{print $1}'); d=$(magick compare -metric DSSIM "$1" "$2" null: 2>&1 | sed 's/.*(\(.*\))/\1/'); printf '%.2f,%.5f' "$p" "$d"; }
echo "machine,frame_set,vs_head_fsr1_psnr,vs_head_fsr1_dssim,vs_base_off_psnr,vs_base_off_dssim,vs_head_off_psnr,vs_head_off_dssim,vs_next_frame_psnr,vs_next_frame_dssim"
for m in 1 2; do
  role="srv$([ $m = 1 ] && echo 2 || echo 1)-cli$m"
  d() { echo "$F/ppm/${role}_$1_below_sdr_r$rep/$fr.ppm"; }
  for v in base_off head_off head_fsr1 headfix_mwsr; do
    f=$(d $v); [ -f "$f" ] || continue
    echo "$m,$v,$(sc "$f" "$(d head_fsr1)"),$(sc "$f" "$(d base_off)"),$(sc "$f" "$(d head_off)"),$(sc "$f" "${f%$fr.ppm}$((fr+1)).ppm")"
  done
done
