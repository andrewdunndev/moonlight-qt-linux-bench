# moonlight-qt Linux bench

Linux bench of client-side upscaling PRs for [moonlight-qt](https://github.com/moonlight-stream/moonlight-qt):
scripts, patches, per-run tables and method, kept per PR head so anyone can check or repeat a result. Today it
covers [PR #1557](https://github.com/moonlight-stream/moonlight-qt/pull/1557) (an FSR1 and an MWSR shader in the
libplacebo Vulkan renderer), tested on two Linux desktops with GPUs from different vendors, streaming from Wolf.

## Findings by PR head

| head | base | first tested | latest remark | verdict | findings |
|---|---|---|---|---|---|
| [`761ba600`](https://github.com/moonlight-stream/moonlight-qt/pull/1557/commits/761ba60098b18ad9058bbef019ad33f51843c5d3) | [`4113dd26`](https://github.com/moonlight-stream/moonlight-qt/commit/4113dd26be0907f2edf1805c7b9fd23766e17161) | 2026-11-20 | 2026-11-21 | MWSR crashes 10 of 10 unpatched; an 11-line acquire/release fix makes it clean and cheaper than FSR1 on both machines | [`heads/761ba600/`](heads/761ba600/) |

Each head directory holds `REMARKS.md` (dated entries, newest first), `runs.csv` (one row per run),
`frame-metrics.csv` (numbers only, no images) and `keylines/`. Upstream master has moved on; only the listed
heads were tested.

## Method
Clients built with the upstream Linux CI recipe in a container, KMSDRM console clients with the Vulkan renderer
and decode, HEVC SDR, a 1080p stream onto a 4K display (ratio 2.00), 60 s per run, n=5 per mode and machine,
each machine taking a turn as the client. Frames from the Vulkan screenshot layer, GPU time from libplacebo pass
timers. Details, deviations and when the bench-only SDL refresh fix is needed are in [`METHOD.md`](METHOD.md).

## Layout
- `bench/` build and run scripts (`bench.sh`, `build.sh`, `run-timing.sh`, `run-frames.sh`, `summarize.sh`,
  `frame-metrics.sh`, `Containerfile.deps`, `Containerfile.sdlfix`)
- `patches/` the fix for the head under test, `timing/` bench-only instrumentation, `bench/` bench-only SDL patch
  (none are for upstream except the fix)
- `heads/<sha>/` findings per PR head
- `METHOD.md`

## Reproduce
Two Linux hosts with podman and sudo over ssh, a Wolf server on each, and a paired moonlight config. The control
machine needs ssh, scp and jq (ImageMagick for the frame metrics):

    export HOST1=... HOST2=... ADDR1=... ADDR2=...       # ssh targets and stream addresses
    export KMS_JSON=... MOONLIGHT_CONFIG=...             # client-side paths: Qt KMS config, paired config dir
    export DECODE_OPTIN=NAME=value                       # only if your stack needs a Vulkan decode opt-in
    export GPU_ARGS1=... GPU_ARGS2=...                   # only if a client needs extra podman args (passthrough)
    export STATS_PARSER=...                              # see below
    bench/bench.sh deps 1; bench/bench.sh deps 2     # plus 'sdlfix 1' / 'sdlfix 2' if needed (METHOD.md)
    bench/bench.sh build 1 base head headfix baseT headT headfixT   # then the same for 2
    bench/run-timing.sh                                              # n=5 matrix with GPU timing
    bench/summarize.sh evidence raw > heads/761ba600/runs.csv
    bench/run-frames.sh; bench/frame-metrics.sh c2 500 > heads/761ba600/frame-metrics.csv   # optional frame metrics

`STATS_PARSER` is a command that reads one client log and prints one tab-separated row (the columns are the
`stats_cols` line `bench.sh` writes into each evidence file; render time is column 11). `summarize.sh` needs it:
without it only the crashed cells reach the table. `GATE_HOOK`, `LOCK_HOOK` and the other env settings are
described at the top of `bench.sh`.

## Add a head
1. Set `HEAD_SHA` (and `BASE_SHA` if the base moved), then `bench.sh build N base head headfix baseT headT headfixT`
   on each machine. Re-check that `patches/` still applies to the new head; add a new patch file if it does not.
2. Run the matrix, with `RAW` and `EV` pointing at a fresh directory, and `IMG=localhost/ml1557-deps:ci-sdlfix`
   if the client needs the SDL fix (see `METHOD.md`). Check `fps_render` is the display rate before trusting times.
3. `bench/summarize.sh $EV $RAW > heads/<sha>/runs.csv`, add `refresh_hz` and `round` columns, and copy the
   frame metrics and key lines.
4. Write `heads/<sha>/REMARKS.md`: a dated entry with what was run (builds, n), findings with numbers, limits.
   Later re-runs add a new dated entry above, never rewrite an old one.
5. Add a row to the table above.

To cover another hardware class, stream shape or renderer, open an issue naming it.
