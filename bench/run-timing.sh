#!/bin/bash
# Round 2: frame capture cells, then the n=5 matrix with GPU-timing builds (T). Env as bench.sh plus REPS (5), SECS.
HERE=$(cd "$(dirname "$0")" && pwd); B=$HERE/bench.sh; REPS=${REPS:-5}
for c in 1 2; do
  for v in "base off" "head off" "head fsr1" "headfix mwsr"; do set -- $c $v
    SECS=30 CAPTURE=300-3 $B cell $1 $2 $3 below sdr c1
  done
done
for r in $(seq 1 "$REPS"); do for c in 1 2; do
  SECS=${SECS:-60} $B cell $c baseT off below sdr $r
  SECS=${SECS:-60} $B cell $c headT off below sdr $r
  SECS=${SECS:-60} $B cell $c headT fsr1 below sdr $r
  SECS=${SECS:-60} $B cell $c headfixT mwsr below sdr $r
  SECS=${SECS:-60} $B cell $c head mwsr below sdr $r   # unpatched head: expected to crash
done; done
echo ALLDONE
