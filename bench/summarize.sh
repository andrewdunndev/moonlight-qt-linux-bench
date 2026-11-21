#!/bin/bash
# One CSV row per evidence/*.kv cell (reads only evidence and keylines; touches no host).
# usage: summarize.sh [EVIDENCE_DIR] [RAW_DIR] > run-table.csv
# Needs the stats row bench.sh gets from STATS_PARSER: a clean cell without one is dropped as voided.
# Excludes skipped cells, frame-capture cells (rep c<N>: the screenshot layer perturbs timing), HDR cells (the server refused HDR, so they are vacuous) and voided cells
# (no assertion, no stats, no crash exit code: the stream dropped before video).
EV=${1:-$(dirname "$0")/../evidence}; RAW=${2:-$(dirname "$0")/../raw}
echo "run_id,machine,build,mode,ratio,crashed,assertion_present,gpu_ms,cpu_render_ms,mwsr_one_pass_line"
{
for f in "$EV"/srv*-cli*_*.kv; do
  [ -e "$f" ] || continue
  asrt=0; k="$RAW/$(basename "${f%.kv}").keylines.txt"
  { [ -f "$k" ] && grep -q Assertion "$k"; } && asrt=1
  awk -F= -v asrt="$asrt" '
    { k=$1; a[k]=substr($0,length($1)+2) }
    END {
      if (a["result"]=="skipped" || a["hdr"]!="sdr" || a["cell"] ~ /_rc[0-9]+$/) exit
      split(a["stats"],s,"\t"); crash=(asrt || a["client_rc"]==139 || a["assertion_lines"]>0)
      if (!crash && s[11]=="") exit
      b=a["build"]; t=""; if (b ~ /T$/) { t="+timing"; sub(/T$/,"",b) }
      if (b=="headfix") b="head+fix"
      run=a["cell"]; sub(/^srv[0-9]-cli[0-9]_/,"",run); run="m" a["client"] "_" run
      gpu=""; if (match(a["gpu_timing"], /mean_us=[0-9.]+/)) gpu=sprintf("%.2f",substr(a["gpu_timing"],RSTART+8,RLENGTH-8)/1000)
      cpu=(crash||s[11]=="")?"":sprintf("%.2f",s[11])
      printf "%s,%s,%s%s,%s,%s,%s,%s,%s,%s,%s\n", run, a["client"], b, t, a["upscale"], (a["mode"]=="below"?"2.00":"1.00"), (crash?"yes":"no"), (asrt||a["assertion_lines"]>0?"yes":"no"), gpu, cpu, (a["mwsr_active_lines"]>0?"yes":"no")
    }' "$f"
done | sort -t, -k2,2 -k3,3 -k4,4 -k1,1
}
