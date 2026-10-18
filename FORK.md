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
| Contribution policy: AI-assisted code is welcome | `AGENTS.md`, `CONTRIBUTING.md`, templates | n/a |

## Keeping in sync

`git fetch upstream` and merge or rebase `main`. Upstream moves fast and some releases have been partly withdrawn
(see its CHANGELOG), so read the diff before deploying anything from `kexts/`.

## Rules for this fork

- A human reviews and tests anything touching the kernel path.
- Test results are labelled: read from source / builds / VM-tested on Turing / not tested.
- Local-only files (notes, logs, built or patched binaries, VM details) live in `.scratch/`, which is gitignored.
