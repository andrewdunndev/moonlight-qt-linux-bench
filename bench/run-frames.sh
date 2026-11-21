#!/bin/bash
# Frame recapture at a later moment (UI fully drawn on both clients): frames 500-502. Env as bench.sh.
HERE=$(cd "$(dirname "$0")" && pwd); B=$HERE/bench.sh
for c in 1 2; do
  for v in "base off" "head off" "head fsr1" "headfix mwsr"; do set -- $c $v
    SECS=40 CAPTURE=500-3 $B cell $1 $2 $3 below sdr c2
  done
done
echo CAPDONE
