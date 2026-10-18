# Contributing

This is a personal fork of [nullmoth/nvidia-macos-driver](https://github.com/nullmoth/nvidia-macos-driver). Bug reports
and pull requests are welcome here. Problems that also exist upstream are best reported upstream (1401 app > Send logs)
as well.

## AI-assisted contributions

AI-assisted code, descriptions and reports are welcome. Whoever submits the change is responsible for it:

- Read every line, and be able to explain it and answer review questions.
- A human must review and test anything touching `kexts/` or `package/` before it is merged. Kernel changes need a boot
  on real hardware or a passthrough VM; say which card.
- Test reports must be honest. Say what you ran, on which card and macOS version, and label each result: read from
  source / builds / VM-tested (card) / not tested. "Builds" is not tested.

## What to work on

[TODO.md](TODO.md) lists known issues and a queue of tasks. Update it in the same change when you finish or learn something.

## Pull requests

- One change per PR: a fix, a feature or a cleanup, not all three.
- Keep the description short: what was wrong, what you changed, how you tested it. Link the issue.
- Commit messages: `component: short summary` under 72 characters (`NVRMFB: fix 165 Hz mode missing`), then a plain
  explanation if one is needed.
- Comments in code explain why the code does what it does. They are not a log of when you found something.
- Do not commit binaries, logs, notes, VM details or credentials. Put them in `.scratch/` (gitignored).

## Licenses

`plugin/`, `kexts/`, `build/`, `package/`: PolyForm Noncommercial 1.0.0. `translator/`: LGPL-3.0-or-later. Mesa
changes: MIT. Firmware: NVIDIA's license. By contributing you agree your change is under the license of the directory it
lands in. Keep `NOTICE` and all license headers.

## Building

See [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md) for the layout of the source and how each part is built.
