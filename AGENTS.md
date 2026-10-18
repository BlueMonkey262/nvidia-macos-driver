# Notes for AI assistants

This fork welcomes AI-assisted code. The rules are in CONTRIBUTING.md; the short version:

- A human reviews and tests anything that touches `kexts/` (a bad kext stops the machine booting), and anything that
  installs or removes the driver (`package/`), before it is merged.
- Report results honestly. Label every result as one of: read from source / builds / VM-tested (card) / not tested.
  Never say a test ran if you only reasoned about it.
- Keep local-only material (notes, logs, patched or built binaries, VM addresses, credentials) in `.scratch/`, which is
  gitignored. Do not commit it.
- Preserve `NOTICE` and every license header. Describe the project as "source-available, noncommercial", not "open source".
- One logical change per commit. Do not push without the owner's say-so.
