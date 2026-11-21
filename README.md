# moonlight-qt Linux bench

At the head of [moonlight-qt PR #1557](https://github.com/moonlight-stream/moonlight-qt/pull/1557), the MWSR
upscaler crashes on every run on two Linux desktops with GPUs from different vendors, and an 11-line change in
`plvk.cpp` stops it. This repo holds the scripts, patches, per-run table and method behind that, so anyone can
check or repeat it.

The PR adds client upscaling (an FSR1 shader and an MWSR shader) to the libplacebo Vulkan renderer. Tested: PR
head `761ba600` against base `4113dd26` (its merge-base, also its base tip), streaming from Wolf. Upstream
master has moved on and was not tested.

## Findings
- **MWSR crashes on both machines.** Unpatched head, MWSR at ratio 2.00: 5 of 5 runs crash per machine (10 of
  10), each with `vk_tex_barrier: Assertion '!tex_vk->held' failed` (libplacebo `gpu_tex.c:30`), seconds
  after start. FSR1 and upscaling off: 0 of 5 crashes per machine.
- **Cause.** `renderMwsrPlanes` (`plvk.cpp`, `pl_dispatch_finish` near line 940) dispatches on the decoder's
  planes without the image acquire and release that `pl_render_image` does itself.
- **Fix.** Call `image->acquire` before and `image->release` after the dispatch
  (`patches/mwsr-acquire-release.patch`, 11 added lines). Patched: 5 of 5 clean per machine, plus 4 earlier clean
  runs, each logging `MWSR drawn in one pass`.
- **Upscaling off, head equals base.** Frames bit-identical on machine 1, within noise on machine 2; CPU render
  time 0.36 vs 0.37 ms and 0.58 vs 0.57 ms (base vs head, three runs each).
- **Patched MWSR is cheaper than FSR1 on the GPU on both machines** (table below).
- **Patched MWSR output looks right.** On one static UI scene, judged by eye plus PSNR (the frames are not
  published): correct geometry, nothing black or garbled, text looked the sharpest. PSNR is about 42 dB against
  FSR1 and 39 dB against off on both machines. PSNR shows that the outputs differ at the edges; it does not
  rank them.

GPU time per frame, ms, mean of five per-run means (`results/run-table.csv`):

| mode | machine 1 | machine 2 |
|---|---|---|
| base, off | 0.31 | 1.88 |
| head, off | 0.32 | 1.89 |
| head, FSR1 | 0.92 | 5.58 |
| head + fix, MWSR | 0.54 | 1.92 |

Machine 2 is display-limited at about 24 fps, so its column is good for ratios between modes and not for
absolute times.

## Not covered
- HDR: the server refused it, so those runs tested nothing.
- Video or motion content: everything here is one static scene.
- X11 or Wayland windowed clients, other renderers and decoders, codecs other than HEVC.
- AppImage packaging, 120 Hz, other stream sizes, base against current master.
- Upstream CI had not run on the PR when tested.

## Method
- Clients built with the upstream Linux CI recipe in a container (deviations in `METHOD.md`).
- KMSDRM console clients, Vulkan renderer and decode, HEVC SDR, `MATCH_DISPLAY_MODE_TO_VIDEO=0`.
- A 1080p stream onto a 4K display (ratio 2.00), showing the Wolf UI, 60 s per run.
- Each machine takes a turn as the client. Five runs per mode on each machine for the main matrix.
- Frames come from the Vulkan screenshot layer, GPU time from libplacebo pass timers.

## Layout
- `bench/` build and run scripts (`bench.sh`, `build.sh`, `run-timing.sh`, `run-frames.sh`, `summarize.sh`,
  `frame-metrics.sh`, `Containerfile.deps`)
- `patches/` the fix, and `timing/` bench-only instrumentation (not for upstream)
- `results/` `run-table.csv`, `frame-metrics.csv` (numbers only, no images), `keylines/`
- `METHOD.md`

## Reproduce
Two Linux hosts with podman and sudo over ssh, a Wolf server on each, and a paired moonlight config. The control
machine needs ssh, scp and jq (ImageMagick for the frame metrics):

    export HOST1=... HOST2=... ADDR1=... ADDR2=...       # ssh targets and stream addresses
    export KMS_JSON=... MOONLIGHT_CONFIG=...             # client-side paths: Qt KMS config, paired config dir
    export DECODE_OPTIN=NAME=value                       # only if your stack needs a Vulkan decode opt-in
    export GPU_ARGS1=... GPU_ARGS2=...                   # only if a client needs extra podman args (passthrough)
    export STATS_PARSER=...                              # see below
    bench/bench.sh deps 1; bench/bench.sh deps 2
    bench/bench.sh build 1 base head headfix baseT headT headfixT   # then the same for 2
    bench/run-timing.sh                                              # n=5 matrix with GPU timing
    bench/summarize.sh evidence raw > results/run-table.csv
    bench/run-frames.sh; bench/frame-metrics.sh c2 500 > results/frame-metrics.csv   # optional frame metrics

`STATS_PARSER` is a command that reads one client log and prints one tab-separated row (the columns are the
`stats_cols` line `bench.sh` writes into each evidence file; render time is column 11). `summarize.sh` needs it:
without it only the crashed cells reach the table. `GATE_HOOK`, `LOCK_HOOK` and the other env settings are
described at the top of `bench.sh`.

## More configurations
Open an issue naming the hardware class, stream shape and renderer to cover, or a new push to the PR to
re-run. Results are added as new rows with the same method.
