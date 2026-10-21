# About this fork

The overlay release is **v2.4.2-v0.3**, on upstream v2.4.2. `package/install.sh` and `package/uninstall.sh` are upstream's. After a successful install, `package/fork-install.sh` adds the fork pieces; `package/fork-uninstall.sh` removes only those.

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
| Hardware HEVC encode on Turing, opt-in | `plugin/NVMTLDevice.m`, `tools/make_nvenc_hevc_t2d.py` | opt-in; VM-tested on the reference card; see [docs/HEVC.md](docs/HEVC.md) |
| H.264 encode regression test | `tools/nvenc_psnr.m`, `tools/test_nvenc_h264.py` | see [docs/H264.md](docs/H264.md) |
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
