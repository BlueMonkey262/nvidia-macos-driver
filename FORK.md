# About this fork

Personal fork of [nullmoth/nvidia-macos-driver](https://github.com/nullmoth/nvidia-macos-driver). The code is
**source-available, noncommercial** (PolyForm Noncommercial 1.0.0 for `plugin/`, `kexts/`, `build/`, `package/`;
LGPL-3.0-or-later for `translator/`; MIT for the Mesa changes; NVIDIA's license for the firmware). `NOTICE` and all
license headers are unchanged. Not affiliated with NullMoth Systems.

Reference hardware: RTX 2060 Super (Turing, TU106, 256 MB BAR1) in a macOS 15.8.1 VM with GPU passthrough.
Nothing here has been run on other cards, and macOS 26 is untested.

## What differs from upstream

| Change | Where | Status |
|---|---|---|
| Hardware H.264 encode on Turing | `plugin/NVMTLDevice.m` (gate), `tools/make_nvenc_t2d.py` | see [docs/H264.md](docs/H264.md) |
| H.264 encode regression test | `tools/nvenc_psnr.m`, `tools/test_nvenc_h264.py` | see [docs/H264.md](docs/H264.md) |
| Metal API coverage map and per-method ratings | `tools/metal_coverage.*`, `tools/metal-ratings.json`, `docs/metal-coverage/` | see [the map](docs/metal-coverage/README.md) |
| Metal behaviour fixes with regression tests (residency use-after-free, LOD-clamp sampler lifetime, kernel times, async compile handlers, nil bindings) | `plugin/NVMTLObjects.m`, `plugin/NVMTLDevice.m`, `tools/test_metal_*.m` | VM-tested on Turing |
| Factorio initialises at default settings: keep 16 command pools and address pages, not 256, under the 4096 NVRM clients per process limit (`NVMTL_POOL_KEEP`) | `plugin/nvmtl_vk.c` | VM-tested on Turing, initialisation only |
| Contribution policy: AI-assisted code is welcome | `AGENTS.md`, `CONTRIBUTING.md`, templates | n/a |

## VM notes

What to know when running in a Proxmox/QEMU macOS VM (a display must be connected at boot, a system daemon that can use a whole vCPU, the CPU label): [docs/VM-NOTES.md](docs/VM-NOTES.md).

## Known issues and what to work on

See [TODO.md](TODO.md): known problems with their test status, and a queue of tasks anyone can pick up.

## Keeping in sync

`git fetch upstream` and merge or rebase `main`. Upstream moves fast and some releases have been partly withdrawn
(see its CHANGELOG), so read the diff before deploying anything from `kexts/`.

## Rules for this fork

- A human reviews and tests anything touching the kernel path.
- Test results are labelled: read from source / builds / VM-tested on Turing / not tested.
- Local-only files (notes, logs, built or patched binaries, VM details) live in `.scratch/`, which is gitignored.
