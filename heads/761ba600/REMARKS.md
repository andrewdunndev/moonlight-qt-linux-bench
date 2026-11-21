# PR #1557 at head 761ba600: remarks

Head `761ba600`, base `4113dd26` (its merge-base). Newest entry first. Numbers are per-run means unless noted;
per-run rows are in `runs.csv` (`refresh_hz` says what the display presented, `round` the date).

## 2026-11-21: machine 2 re-run at 60 Hz

**Why.** In the first two rounds machine 2 as client presented at about 24 Hz (`fps_render` 23.8 on average, 58%
pacer drops, 33 ms queue), not 60. The cause was our bench, not the PR and not the display: SDL 3.4.20's KMSDRM Vulkan
surface code takes the first listed `VkDisplayModeKHR` whose size equals the window and ignores refresh rate (SDL
main sorts by refresh first). On that machine's driver the first listed 4K mode is 23.976 Hz. The display's own
mode list included 4K60. Control: same cell on the stock image, `fps_render` 23.79; on the fixed image, 59.56.
Shipped moonlight is not affected: its upstream Linux build has SDL KMSDRM off, we enabled it for the bench.

**Fix (bench only, no host change).** `patches/bench/sdl-kmsdrm-vulkan-refresh.patch` (the upstream-main sort,
backported) layered on the deps image by `bench/Containerfile.sdlfix`; cells run with
`IMG=localhost/ml1557-deps:ci-sdlfix`. Moonlight builds are unchanged. See "SDL refresh-rate fix" in `METHOD.md`.

**Run.** Machine 2 as client, machine 1 as server, 1080p to 4K (ratio 2.00), HEVC SDR, 60 s per run, n=5 per
mode, same builds as before (`base`, `head`, `headfix`, timing variants). 25 runs, all started and ended on the
timer except the 5 expected crashes. Machine 1 was not re-run (it was already presenting at 60).

| mode (machine 2, 60 Hz) | fps_render | pacer drop % | CPU render ms | GPU ms (mean, sd) | crashes |
|---|---|---|---|---|---|
| base, off | 59.77 | 0.08 | 0.44 | 2.38 (0.55) | 0/5 |
| head, off | 59.77 | 0.08 | 0.44 | 2.73 (0.32) | 0/5 |
| head, FSR1 | 59.72 | 0.08 | 0.64 | 5.32 (0.23) | 0/5 |
| head + fix, MWSR | 59.75 | 0.08 | 0.44 | 2.56 (0.47) | 0/5 |
| head, MWSR (unpatched) | n/a | n/a | n/a | n/a | 5/5 |

`fps_render` ranged 59.71 to 59.78 across the 20 non-crash runs; sd is the sample sd of the five per-run means.
The 5 unpatched MWSR runs each died with `vk_tex_barrier: Assertion '!tex_vk->held' failed` (exit 139; the
assertion lines are in `keylines/assertions.txt`, suffix `_60hz`).

**Verdicts, unchanged.**
- Unpatched head MWSR crashes 5 of 5 on machine 2 (10 of 10 across both machines); the fix gives 5 of 5 clean.
- Upscaling off, head equals base: GPU 2.73 vs 2.38 ms is inside run-to-run spread (Welch t about 1.2), CPU 0.44
  vs 0.44.
- Patched MWSR is cheaper than FSR1 on the GPU on both machines: 2.56 vs 5.32 ms here (machine 1: 0.54 vs 0.92).

**What changed.** Machine 2's absolute times at 60 Hz are higher than the 24 Hz ones (GPU 2.38 to 2.73 ms for
off, against 1.88 to 1.89) because the GPU now renders 60 frames a second instead of 24; the FSR1 gap over off
shrank from +3.69 ms to +2.59 ms; patched MWSR against off went from +0.03 to -0.17 ms (against base +0.18), which
is noise-level. The earlier "display-limited" caveat on machine 2 is withdrawn: the limit was the SDL build in
our bench. The 1.92 vs 5.58 ms pair below is superseded by 2.56 vs 5.32 ms.

**Limits.** One machine re-run, n=5, one static scene, mean of per-run means. The 4K mode could not be read back
from KMS on this driver (the CRTC reads inactive while the client streams), so the evidence for 60 Hz is the
presented frame rate. Machine 1's rows are untouched.

## 2026-11-20: rounds 1 and 2

**Run.** Builds per machine: `base`, `head`, `headfix` (head plus `patches/mwsr-acquire-release.patch`), and `T`
variants with bench-only GPU timing. Both machines as client in turn, KMSDRM console client, 1080p to 4K, HEVC
SDR, 60 s per run. Main matrix n=5 per mode and machine; earlier cells n=1 to 3, a 4K stream (ratio 1.00)
control at n=1. Frames from the Vulkan screenshot layer, frames 500 and 501 of each mode.

**Findings.**
- **MWSR crashes on both machines.** Unpatched head, MWSR at ratio 2.00: 5 of 5 runs crash per machine (10 of
  10), each with `vk_tex_barrier: Assertion '!tex_vk->held' failed` (libplacebo `gpu_tex.c:30`), seconds after
  start. FSR1 and upscaling off: 0 of 5 crashes per machine.
- **Cause.** `renderMwsrPlanes` (`plvk.cpp`, `pl_dispatch_finish` near line 940) dispatches on the decoder's
  planes without the image acquire and release that `pl_render_image` does itself.
- **Fix.** `image->acquire` before and `image->release` after the dispatch
  (`patches/mwsr-acquire-release.patch`, 11 added lines; path unchanged). Patched: 5 of 5 clean per machine, plus
  4 earlier clean runs, each logging `MWSR drawn in one pass`.
- **Upscaling off, head equals base.** Frames bit-identical on machine 1, within noise on machine 2; CPU render
  time 0.36 vs 0.37 ms (machine 1) and 0.58 vs 0.57 ms (machine 2), base vs head, three runs each.
- **Frames.** Patched MWSR output on one static UI scene, judged by eye plus PSNR (frames not published): correct
  geometry, nothing black or garbled, text looked the sharpest. PSNR about 42 dB against FSR1 and 39 dB against
  off on both machines (`frame-metrics.csv`). PSNR shows the outputs differ at the edges; it does not rank them.
- **GPU time per frame, ms, mean of five per-run means.** Machine 2 is at 24 Hz here (superseded, see 2026-11-21).

| mode | machine 1 (60 Hz) | machine 2 (at 24 Hz) |
|---|---|---|
| base, off | 0.31 | 1.88 |
| head, off | 0.32 | 1.89 |
| head, FSR1 | 0.92 | 5.58 |
| head + fix, MWSR | 0.54 | 1.92 |

**Limits.** Machine 2 presented at about 24 Hz in these rounds (cause above), so its column was good for ratios
between modes only. Not covered: HDR (the server refused it, so those runs tested nothing), video or motion
content (one static scene), windowed X11 or Wayland clients, other renderers and decoders, codecs other than
HEVC, packaging, 120 Hz, other stream sizes, base against current master. Upstream CI had not run on the PR.
