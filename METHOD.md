# Method

## Build recipe versus upstream
Clients are built the way upstream's Linux AppImage workflow builds them, inside a container that
replicates its CI image (`bench/Containerfile.deps`, `bench/build.sh`):

- Ubuntu 22.04, the same apt set, the same pinned SDL3, sdl2-compat, SDL_ttf, libva, libplacebo, dav1d and FFmpeg.
- The qmake line from `scripts/build-appimage.sh` verbatim (`CONFIG+=disable-wayland CONFIG+=disable-libdrm
  DEFINES+=APP_IMAGE`), LTO flags, `make release`.

Deviations, all forced by the test machines being console hosts with no compositor:

- SDL3 is built with KMSDRM on (upstream CI builds it off) so the client can reach the display directly.
- No linuxdeploy or AppImage packaging; the built tree runs from a container mount.
- Distro Vulkan and VA drivers added at runtime; `sdl2.pc` aliased to `sdl2-compat.pc` so qmake finds SDL.
- The Vulkan video-decode opt-in some driver stacks need is passed as an env var (`DECODE_OPTIN`).

Builds per machine: `base` (merge-base 4113dd26), `head` (PR head 761ba600), `headfix` (head plus
`patches/mwsr-acquire-release.patch`). The T variants add a bench-only timing patch (`patches/timing/`).
All builds finish with 0 errors and the same warning count (13) base versus head.

## Stream shape
Two Linux desktops with GPUs from different vendors (machine 1, machine 2), each 4K display, KMSDRM console
client, Vulkan renderer (libplacebo), Vulkan decode, HEVC SDR, 60 fps. Wolf runs on the other machine; roles
swap so each machine is measured as the client. Stream is 1080p at 20 Mbit/s onto the 4K display (ratio 2.00,
the case upscaling exists for), with a 4K, 50 Mbit/s stream (ratio 1.00) as a control at n=1. The app is the
Wolf UI, a static scene; 60 s per cell (30 to 40 s for frame capture).
`MATCH_DISPLAY_MODE_TO_VIDEO=0` is set: on KMSDRM the client otherwise switches the display to the stream
mode, which would remove the upscale this bench measures. The Qt platform is `offscreen` so SDL KMSDRM
holds DRM master.

## Frame capture
The LunarG Vulkan screenshot layer (`VK_LAYER_LUNARG_screenshot`) writes the presented 4K swapchain image
for chosen frame numbers with no code change. Frames 500 and 501 of each mode were compared (PSNR in dB,
120 means identical; DSSIM, 0 means identical). The noise floor is frame 500 against 501 of the same cell.
Frame 300 was discarded (the UI was not yet drawn). Capture cells are excluded from timing because the layer
perturbs it. Quality was judged by eye plus PSNR and DSSIM (no perceptual metric), on one static scene. The images
themselves are not published.

## GPU timing
`patches/timing/` reads libplacebo pass timers (GPU timestamp queries), sums all passes per frame, and
prints mean, sd and p95 per run (`MLGPUT` line). This is GPU time, not CPU render time; `cpu_render_ms` in
the run table is the client's wall time around render. The instrumentation changes nothing else, and the
off-path was measured with it on both base and head.

## n and voided runs
n=5 per cell and machine for the timing matrix; earlier cells n=1 to 3. A run is voided when the stream
drops before video starts (no assertion, no stats, no crash exit code). Voided runs are rerun, not counted,
and not in the table; three were voided and rerun, and the unpatched one crashed again. A crash is
the process dying with the libplacebo assertion (exit 139). HDR cells were vacuous (the server refused
HDR, the stream stayed SDR) and are left out.
