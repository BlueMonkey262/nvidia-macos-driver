# What can it do, and which games run

All results are from one RTX 2060 Super (Turing, 8 GB VRAM, 256 MB BAR1) in a macOS 15.8.1 VM with GPU passthrough.
They do not qualify other cards. Each line says how it is known: **VM-tested** (run on that card), **user-reported**,
or **read from source**. A game that reaches its menu has not passed gameplay. Last updated 2026-10-19.

## What can it do?

**Things this fork does that upstream does not (on Turing, RTX 20 / GTX 16):**

- **Hardware H.264 encode.** Upstream's encoder was written for Blackwell (RTX 50) and tiles frames in that layout; this
  fork patches it to write the classic layout so Turing's NVENC works through VideoToolbox. Apps that use VideoToolbox,
  such as Sunshine, get hardware encode instead of falling back to software. How it works and what the patch is:
  [H264.md](H264.md).
- **Streaming from the VM.** A plugin hook removes the low-latency rate-control request that VideoToolbox refuses on a
  non-Apple GPU, and caches the encoder's property lookup that fails while a session is open. That is what lets
  Sunshine/Moonlight run on hardware encode ([H264.md](H264.md)). One encoder session per process is a known limit.
- **Optional bitrate control** (`NVMTL_VT_RC=1`), because the library's own rate control ignores the requested bitrate.
- **A rated map of the whole Metal API**, with a regression test behind many ratings: [metal-coverage/](metal-coverage/README.md).
- **Metal fixes with tests that fail on the old plugin and pass on the new one**: a texture-residency use-after-free,
  LOD-clamp sampler lifetime, real command-buffer kernel times, asynchronous compile completion handlers, nil bindings,
  honest retained-reference flags and others (see `tools/test_metal_*.m` and the Git history).
- **Factorio initialises at default settings.** The plugin used to keep 256 command pools and address pages, which used
  up the kernel's limit of 4096 NVRM clients per process; it now keeps 16 (`NVMTL_POOL_KEEP`).

**Codec speed (VM-tested, 1080p, idle VM, median of repeated runs; H.264 from [H264.md](H264.md), HEVC from the HEVC branch's docs):**

| Codec | 720p | 1080p | 1080p median latency | CPU per frame |
|---|---|---|---|---|
| H.264 encode (installed baseline, low-BAR patch only) | 847 fps | 421 fps | 2.34 ms | 2.38 ms |
| HEVC encode (experimental, opt-in `NVMTL_NVENC_HEVC=1`) | 662-664 fps | 299-301 fps | n/a | 3.3 ms |

The encoder is CPU-bound (CPU time per frame is about equal to wall time per frame), so one core is the limit.
Optional patches (`--direct-row`, `--short-zero`) lower H.264 CPU time further; see the table in [H264.md](H264.md).
HEVC encode is on a separate branch, `hevc-experimental`, and is not part of `staging` yet. These are throughput
benchmarks of the encoder, not game-streaming quality: a short Sunshine/Moonlight desktop run held 60 fps at 1080p, and
noisy content fell to about 40 fps.

## Games

| Game | Status on our driver | How it is known |
|---|---|---|
| Terraria | Title screen renders (SDL_GPU on Metal); played earlier, 41 fps after 70 s in the smoke test | VM-tested; gameplay user-reported |
| Cities: Skylines | Loads a large real save and renders correctly, but only about 5 fps | VM-tested (2026-10-19) |
| No Man's Sky | Main menu renders at about 29 fps; a save loaded for the first time on 2026-10-19; an earlier run hit a fatal error after about 17 minutes of shader loading | VM-tested, user-reported |
| Kerbal Space Program 1.12.5 | Runs through OpenGL-on-Metal; menu renders, atmospheric flight worked at low fps | VM-tested menu, user-reported flight |
| Factorio 2.0.77 | Initialises at default texture settings after the client-limit fix; nothing past initialisation tested | VM-tested, init only |

### Known problems, with the evidence

- **Cities: Skylines at 5 fps.** In a stack sample, 97% of a 5-second window was the render thread waiting in
  `replaceRegion:` for the GPU, because every texture upload waits (`NVMTL_ASYNC_TEX_UPLOAD` is off by default). The
  card is also full: images hold about 6.1 GB, and the plugin's free-memory figure wrongly reports 8192 MB free, so
  allocations fail and are retried. Shader pipeline creation fails for terrain, buildings, vehicles and roads in the log.
  Status: analysed (read from logs and source), fixes in progress, not yet tested.
- **No Man's Sky.** The earlier fatal error was a null call in the texture argument-buffer binding after the card ran
  out of video memory; the cause was never confirmed. Whether the 2026-10-19 plugin fixed it is not established.
- **Factorio** past initialisation, and any game with a save, are untested unless the table says otherwise.
- **macOS 26** is untested.

Reports and measurements welcome; please label them the same way (VM-tested / user-reported / read from source).
