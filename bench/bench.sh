#!/bin/bash
# moonlight-qt PR #1557 Linux bench. Runs from a control machine; builds and clients run in podman containers
# on two Linux hosts (host 1 and host 2) that also act as Wolf servers for each other (roles swap per cell).
# Subcommands:
#   deps N                       build the CI-replica dependency image on machine N (1|2)
#   build N [LABEL...]           build clients on machine N (default: base head). Labels: base head headfix
#                                baseT headT headfixT (fix = patches/mwsr-acquire-release.patch,
#                                T = + bench-only timing patch from patches/timing/)
#   cell CLIENT BUILD UPSCALE MODE HDR REP   one measured session; CLIENT is the machine (1|2) running the client,
#                                the other machine is the Wolf server. BUILD as above, UPSCALE off|fsr1|mwsr,
#                                MODE below (1080p->4K, ratio 2.00) | equal (4K, ratio 1.00), HDR sdr|hdr
#   matrix CLIENT                the round-1 matrix for one role assignment
#   clean N                      remove everything the bench put on machine N
# Required env: HOST1 HOST2 (ssh targets), ADDR1 ADDR2 (stream addresses of the Wolf servers).
# Optional env: SECS (60); APP (Wolf UI); DECODE_OPTIN (NAME=value passed to the client container: the vendor's
#   Vulkan video decode opt-in, if the stack needs one); GPU_ARGS1 GPU_ARGS2 (extra podman args per machine, e.g.
#   device passthrough); KMS_JSON (client-side KMS config path); MOONLIGHT_CONFIG (client-side paired config
#   dir, copied per cell); WOLF_SOCK (server-side Wolf API socket, empty = skip session cleanup);
#   GATE_HOOK (command run with both ssh targets before a cell; nonzero skips it); LOCK_HOOK (command prefix
#   that wraps a cell, e.g. a lock); STATS_PARSER (local command: reads a client log, prints one tab-separated
#   stats row, see stats_cols; summarize.sh needs it: without it only crashed cells reach the table and
#   cpu_render_ms stays empty); QPA (Qt platform, offscreen leaves DRM master to SDL KMSDRM); DISPLAY_MODE.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(dirname "$HERE")
RAW=${RAW:-$ROOT/raw}; EV=${EV:-$ROOT/evidence}; mkdir -p "$RAW" "$EV"
: "${HOST1:?}" "${HOST2:?}" "${ADDR1:?}" "${ADDR2:?}"
SECS=${SECS:-60}; APP=${APP:-Wolf UI}; QPA=${QPA:-offscreen}; DISPLAY_MODE=${DISPLAY_MODE:-borderless}
DECODE_OPTIN=${DECODE_OPTIN:-}; KMS_JSON=${KMS_JSON:-/etc/kms.json}; MOONLIGHT_CONFIG=${MOONLIGHT_CONFIG:-/etc/moonlight-config}
WOLF_SOCK=${WOLF_SOCK-/run/wolf/wolf.sock}
BASE_SHA=${BASE_SHA:-4113dd26be0907f2edf1805c7b9fd23766e17161}
HEAD_SHA=${HEAD_SHA:-761ba60098b18ad9058bbef019ad33f51843c5d3}
IMG=localhost/ml1557-deps:ci
WORK=/var/tmp/ml1557-work
host() { eval echo "\$HOST$1"; }
addr() { eval echo "\$ADDR$1"; }
gpuargs() { eval echo "\${GPU_ARGS$1:-}"; }
other() { [ "$1" = 1 ] && echo 2 || echo 1; }
rh() { local h=$1; shift; ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 "$h" "$@"; }
sha_of() { case ${1%%[fT]*} in base) echo "$BASE_SHA" ;; head) echo "$HEAD_SHA" ;; esac; }

cmd_deps() { # build the dependency image (same recipe as upstream CI, see Containerfile.deps)
  local h; h=$(host "$1")
  scp -q "$HERE/Containerfile.deps" "$HERE/build.sh" "$h:/var/tmp/" || return 1
  rh "$h" "t0=\$(date +%s); sudo -n podman build --network host -t $IMG -f /var/tmp/Containerfile.deps /var/tmp >/var/tmp/ml1557-deps.log 2>&1; rc=\$?; echo deps_rc=\$rc deps_s=\$((\$(date +%s)-t0))"
}

cmd_build() { # clients on one machine; one build.kv line each
  local n=$1 h label sha out; h=$(host "$n"); shift; local labels=${*:-base head}
  scp -q "$HERE/build.sh" "$h:/var/tmp/ml1557-build.sh"
  rh "$h" "sudo -n mkdir -p $WORK && sudo -n cp /var/tmp/ml1557-build.sh $WORK/build.sh && sudo -n chmod +x $WORK/build.sh"
  for label in $labels; do
    local fam=${label%%[fT]*} pl=""; sha=$(sha_of "$fam")
    case $label in *fix*) pl="mwsr-acquire-release.patch" ;; esac
    case $label in *T) pl="$pl timing-$fam.patch"; case $label in *fixT) pl="$pl timing-mwsr.patch" ;; esac ;; esac
    scp -q "$ROOT"/patches/*.patch "$ROOT"/patches/timing/*.patch "$h:/var/tmp/"
    rh "$h" "sudo -n mkdir -p $WORK/patches && sudo -n cp /var/tmp/*.patch $WORK/patches/"
    out=$(rh "$h" "sudo -n podman run --rm --network host -e PATCHES='$pl' -v $WORK:/work:Z $IMG /work/build.sh $label $sha 2>&1 | tail -n 3")
    echo "$out" | tail -n1
    rh "$h" "sudo -n grep 'warning:' $WORK/out-$label/make.log | sed 's/^[^ ]* //' | sort | uniq -c | sort -rn | head -20" >"$RAW/build-m$n-$label.warnings.txt" 2>/dev/null
    echo "machine=$n label=$label sha=$sha $(echo "$out" | grep build_rc || echo "build_rc=none $(echo "$out" | tail -n1)")" >>"$EV/build.kv"
  done
}

cmd_cell() { # retry while the gate hook is closed; 8 tries, 45 s apart
  local n=0 id="srv$(other "$1")-cli$1_${2}_${3}_${4}_${5}_r$6"
  while [ $n -lt 8 ]; do
    ${LOCK_HOOK:-} "$0" _cell "$@"
    grep -q 'reason=gate' "$EV/$id.kv" 2>/dev/null || return 0
    n=$((n+1)); sleep 45
  done
}

cmd__cell() {
  local cn=$1 build=$2 up=$3 mode=$4 hdr=$5 rep=$6 sn; sn=$(other "$cn")
  local cli srv; cli=$(host "$cn"); srv=$(host "$sn")
  local id="srv$sn-cli${cn}_${build}_${up}_${mode}_${hdr}_r$rep" res br args cap='' isbase t0 w0
  case $mode in below) res=1920x1080; br=20000 ;; equal) res=3840x2160; br=50000 ;; esac
  args="--resolution $res --fps 60 --bitrate $br --video-codec hevc --video-decoder hardware --display-mode $DISPLAY_MODE --no-quit-after"
  [ "$hdr" = hdr ] && args="$args --hdr"
  case $up in
    off) args="$args --no-video-enhancement" ;;
    fsr1) args="$args --video-enhancement --super-resolution-mode fsr1-upscaler" ;;
    mwsr) args="$args --video-enhancement --super-resolution-mode mwsr-upscaler" ;;
  esac
  case $build in base*) isbase=1 ;; *) isbase=0 ;; esac
  [ $isbase = 1 ] && [ "$up" != off ] && { echo "skip $id: base has no upscaling option"; return 0; }
  [ $isbase = 1 ] && args=${args/ --no-video-enhancement/}
  if [ -n "${GATE_HOOK:-}" ] && ! $GATE_HOOK "$srv" "$cli"; then
    echo "skip $id: gate hook closed"; echo "cell=$id result=skipped reason=gate" >"$EV/$id.kv"; return 0
  fi
  rh "$cli" "sudo -n rm -rf $WORK/xdg && sudo -n cp -a $MOONLIGHT_CONFIG $WORK/xdg && sudo -n podman rm -f ml1557-stream >/dev/null 2>&1; true"
  if [ -n "${CAPTURE:-}" ]; then # Vulkan screenshot layer: presented frames of the listed numbers, written as PPM
    rh "$cli" "sudo -n rm -rf $WORK/shots && sudo -n mkdir -p $WORK/shots && sudo -n chmod 777 $WORK/shots"
    cap="-e VK_INSTANCE_LAYERS=VK_LAYER_LUNARG_screenshot -e VK_SCREENSHOT_FRAMES=$CAPTURE -e VK_SCREENSHOT_DIR=/shots -v $WORK/shots:/shots:Z"
  fi
  local optin=""; [ -n "$DECODE_OPTIN" ] && optin="-e $DECODE_OPTIN"
  local log=$RAW/$id.log gpu=$RAW/$id.gpu
  : >"$log"
  rh "$cli" "timeout -s TERM -k 15 $((SECS+120)) sudo -n podman run --rm --name ml1557-stream --network host --device /dev/dri $(gpuargs "$cn") $cap \
      -e QT_QPA_PLATFORM=$QPA $optin -e MATCH_DISPLAY_MODE_TO_VIDEO=0 -e QT_QPA_EGLFS_KMS_CONFIG=/kms.json -e XDG_CONFIG_HOME=/xdg -e SDL_AUDIODRIVER=dummy \
      -v $KMS_JSON:/kms.json:ro,Z -v $WORK/xdg:/xdg:Z -v $WORK/out-$build:/opt/ml:ro,Z $IMG \
      /opt/ml/usr/bin/moonlight stream $(addr "$sn") '$APP' $args" 2>"$log" >/dev/null &
  local pid=$! i=0 started=0
  while kill -0 $pid 2>/dev/null && [ $i -lt 240 ]; do grep -q 'Starting video stream' "$log" && { started=1; break; }; sleep 0.5; i=$((i+1)); done
  if [ $started = 1 ]; then
    t0=$(date +%s)
    rh "$cli" "n=$SECS; a=\$(awk '/^cpu /{print \$2+\$3+\$4+\$7+\$8, \$2+\$3+\$4+\$5+\$6+\$7+\$8}' /proc/stat); sleep \$n; \
      b=\$(awk '/^cpu /{print \$2+\$3+\$4+\$7+\$8, \$2+\$3+\$4+\$5+\$6+\$7+\$8}' /proc/stat); echo CPU \$a \$b" >"$gpu" 2>/dev/null &
    local sp=$!
    while kill -0 $pid 2>/dev/null && [ $(($(date +%s)-t0)) -lt "$SECS" ]; do sleep 0.5; done
    wait $sp 2>/dev/null
  fi
  local ended=server
  if kill -0 $pid 2>/dev/null; then ended=timer; rh "$cli" "sudo -n podman stop -t 15 ml1557-stream" >/dev/null 2>&1; fi
  wait $pid 2>/dev/null; local rc=$?
  rh "$cli" "sudo -n podman run --rm --network host -e XDG_CONFIG_HOME=/xdg -v $WORK/xdg:/xdg:Z -v $WORK/out-$build:/opt/ml:ro,Z $IMG /opt/ml/usr/bin/moonlight quit $(addr "$sn")" >/dev/null 2>&1
  local left=NA sid
  if [ -n "$WOLF_SOCK" ]; then # end any session the client left behind on the Wolf server
    for sid in $(rh "$srv" "sudo -n curl -sf --unix-socket $WOLF_SOCK http://localhost/api/v1/sessions" | jq -r '.sessions[] | (.session_id // .client_id // .id // empty) | tostring' 2>/dev/null); do
      jq -nc --arg s "$sid" '{session_id:$s}' | rh "$srv" "sudo -n curl -s --unix-socket $WOLF_SOCK -X POST -H 'Content-Type: application/json' -d @- http://localhost/api/v1/sessions/stop" >/dev/null 2>&1
    done
    sleep 3
    left=$(rh "$srv" "sudo -n curl -sf --unix-socket $WOLF_SOCK http://localhost/api/v1/sessions" | jq '.sessions|length' 2>/dev/null)
  fi
  if [ -n "${CAPTURE:-}" ]; then mkdir -p "$ROOT/frames/ppm/$id"; rh "$cli" "sudo -n tar -C $WORK/shots -c ." | tar -C "$ROOT/frames/ppm/$id" -x; fi
  local row=""; [ -n "${STATS_PARSER:-}" ] && row=$($STATS_PARSER "$log" 2>/dev/null | tail -n1)
  local cavg
  cavg=$(awk '/^CPU/{ub=$2;ut=$3;vb=$4;vt=$5; if(vt>ut)printf "%.1f",100*(vb-ub)/(vt-ut)}' "$gpu" 2>/dev/null)
  {
    echo "cell=$id"; echo "run_utc=$(date -u +%FT%TZ)"
    echo "server=$sn"; echo "client=$cn"; echo "build=$build"; echo "build_sha=$(sha_of "$build")"
    echo "upscale=$up"; echo "mode=$mode"; echo "stream_res=$res"; echo "hdr=$hdr"; echo "secs=$SECS"
    echo "started=$started"; echo "ended=$ended"; echo "client_rc=$rc"; echo "sessions_left=${left:-NA}"
    echo "stats_cols=WxH fps_in fps_dec fps_render host_lat_avg net_drop_pct jitter_drop_pct rtt decode_ms queue_ms render_ms codec decoder"
    echo "stats=$row"
    echo "renderer=$(grep -m1 -o "Renderer '[^']*' chosen" "$log")"
    echo "enh_probe_line=$(grep -m1 'Video Enhancement:' "$log")"
    echo "mwsr_active_lines=$(grep -c 'MWSR drawn in one pass' "$log")"
    echo "assertion_lines=$(grep -c 'Assertion' "$log")"
    echo "shader_errors=$(grep -c -E 'Failed to parse the|Cannot open GLSL|one-pass shader (was refused|failed)|pl_render_image\(\) failed' "$log")"
    echo "crash_lines=$(grep -c -i -E 'segmentation|SIGSEGV|abort|core dumped|terminate called|vk.*device lost|VK_ERROR' "$log")"
    echo "client_cpu_busy_pct=${cavg:-NA}"
    echo "gpu_timing=$(grep -o 'MLGPUT.*' "$log" | tail -n1)"
    echo "frame_capture=${CAPTURE:-none}"
  } >"$EV/$id.kv"
  grep -E 'Assertion|MWSR drawn|Video Enhancement:|Renderer ' "$log" | head -10 >"$RAW/$id.keylines.txt"
  echo "$id started=$started ended=$ended rc=$rc"
}

cmd_matrix() { # one role assignment; reps: off paths 3x below (noise), the rest once
  local c=$1 u m r b
  for r in 1 2 3; do cmd_cell "$c" base off below sdr $r; cmd_cell "$c" head off below sdr $r; done
  cmd_cell "$c" base off equal sdr 1; cmd_cell "$c" head off equal sdr 1
  for u in fsr1 mwsr; do for m in below equal; do cmd_cell "$c" head $u $m sdr 1; done; done
}

cmd_clean() { # remove everything the bench put on a machine
  local h; h=$(host "$1")
  rh "$h" "sudo -n podman rm -f ml1557-stream >/dev/null 2>&1; sudo -n podman rmi -f $IMG >/dev/null 2>&1; sudo -n podman image prune -f >/dev/null 2>&1; sudo -n rm -rf $WORK /var/tmp/ml1557* /var/tmp/Containerfile.deps /var/tmp/build.sh /var/tmp/*.patch; echo cleaned $1"
}

c=${1:-}; shift || true
case $c in deps|build|cell|_cell|matrix|clean) "cmd_$c" "$@" ;; *) sed -n '2,22p' "$0"; exit 2 ;; esac
