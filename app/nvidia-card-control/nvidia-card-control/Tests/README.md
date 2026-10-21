# Bundled tests

From the repository root on an Intel-capable Mac with Xcode or command line tools:

```sh
app/scripts/build-tests.sh
tools/nvmtlctl test list --json
NVMTL_TESTS_DIR="$PWD/app/nvidia-card-control/nvidia-card-control/Tests" tools/nvmtlctl test run encode-h264 --param size=1080p --param seconds=6 --json
```

Build before building the app in Xcode. The synchronized source folder supplies
these files as bundle resources. Outputs are x86_64 executables, ignored by git;
manifest.tsv and this README stay tracked. No driver is installed or changed.
The compiler reads tools/nvenc_matrix.m in place so its ../plugin include works.
The companion nvenc_gpu_load is built for manual stress testing (see
docs/CODEC-TESTING.md); it is deliberately not run by run-all.

The CLI searches for a readable manifest.tsv in this order: NVMTL_TESTS_DIR,
Contents/Resources/Tests in its app bundle, then
/Library/Application Support/GPU Control/tests. The first manifest and its
sibling programs form one catalog; directories are never mixed. In the source
checkout the bundled CLI also recognizes its adjacent Tests directory.
Missing/non-executable programs appear unavailable, and a direct run skips them.
If no manifest can be found, the command exits nonzero with a diagnostic on stderr.

## Manifest format (nvmtl-tests-v1)

This replaces the contract's manifest.json to avoid a Python/jq runtime dependency.
Records are UTF-8, one per line, with **literal tabs** separating nonempty fields;
blank lines and # comments are ignored. No field may contain a tab or newline.
Use `-` for unused fields. This is packaged data, never sourced as shell code.

* `T ID TITLE GROUP DESCRIPTION ESTIMATED_SECONDS RUNNER PROGRAM`
* `P ID KEY LABEL TYPE DEFAULT CHOICES MIN MAX`

T order defines list/run-all order. P order defines parameter order for its ID.
TYPE is `choice` (comma-separated CHOICES) or `int` (inclusive MIN/MAX).
RUNNER is `encode`, `bringup`, `program` or `suite`. PROGRAM is a basename;
only suite uses the literal `test_metal_*` glob. Each ID and parameter key must
be unique. needs_root is always false. Estimates are approximate wall seconds;
actual encode duration includes source generation and software decode.

Encode runners use nvenc_matrix's ten-argument interface with 60 nominal fps,
one session, NVMTL_VT_RC=1 and NVENC_VT_VERBOSE=1; HEVC also uses
NVMTL_NVENC_HEVC=1 in the child. Bring-up takes one codec argument and enables
the same verbose output. These settings affect only the child test process.
Results include the last 40 combined stdout/stderr lines (suite details instead
list every program as PASS/FAIL/SKIP), numeric metrics and known recovery hints.
Exit 77 means skip, other nonzero test exits mean fail (126/127 mean error).
Invalid/unknown parameters produce status error with CLI exit 0. Tool setup
failures (for example no manifest or no temporary directory) exit nonzero.

For encode, SESSION supplies correctness, frame counts, bitrate, PSNR and p95;
the single-session JSON supplies more precise metrics, including fps. The CLI
reads only known scalar numeric keys from the nvenc_matrix-produced JSON;
it is not a general JSON parser. Missing SESSION, correct=0, or a nonzero exit
fails the test. No PSNR or bitrate threshold is imposed beyond the probe's
correctness check. Existing Metal regressions may fail on the installed driver;
this catalog does not claim they pass. Mac build, bundle resource execution,
and card results require the owner's validation.
