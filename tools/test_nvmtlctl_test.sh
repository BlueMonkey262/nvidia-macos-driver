#!/bin/bash
# Linux/macOS CLI regression tests. Python 3 is used only here for JSON assertions;
# nvmtlctl and its manifest reader have no Python/jq dependency.
# Run from any directory: bash tools/test_nvmtlctl_test.sh
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
python3 - "$ROOT" <<'PY'
import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
cli = root / 'tools/nvmtlctl'
manifest = root / 'app/nvidia-card-control/nvidia-card-control/Tests/manifest.tsv'
assert cli.read_bytes() == (manifest.parent.parent / 'nvmtlctl').read_bytes(), 'bundled CLI differs'
checks = 0
with tempfile.TemporaryDirectory(prefix='nvmtl CLI tests ') as tmp:
    tests = Path(tmp) / 'Tests with spaces'
    tests.mkdir()
    shutil.copyfile(manifest, tests / 'manifest.tsv')
    trace = Path(tmp) / 'calls'
    env = dict(os.environ, NVMTL_TESTS_DIR=str(tests), TEST_TRACE=str(trace))

    def call(*args, mode='pass', binary=cli, json_output=True):
        global checks
        command = [str(binary), 'test', *args]
        if json_output:
            command.append('--json')
        p = subprocess.run(command, env=dict(env, STUB_MODE=mode), text=True, capture_output=True)
        assert p.returncode == 0, (command, p.returncode, p.stdout, p.stderr)
        assert not p.stderr, p.stderr
        checks += 1
        if not json_output:
            return p.stdout
        value = json.loads(p.stdout)
        results = value if isinstance(value, list) else [value]
        for r in results:
            if 'status' in r:
                assert set(r) == {'id', 'status', 'started', 'duration_s', 'summary', 'metrics', 'details', 'hint'}, r
                assert r['status'] in ('pass', 'fail', 'skip', 'error')
                datetime.datetime.strptime(r['started'], '%Y-%m-%dT%H:%M:%SZ')
                assert isinstance(r['duration_s'], (int, float)) and r['duration_s'] >= 0
                assert all(type(v) in (int, float) for v in r['metrics'].values()), r
        return value

    def stub(name, body):
        path = tests / name
        path.write_text('#!/bin/bash\nset -u\n' + body)
        path.chmod(0o755)
        return path

    ids = ['encode-h264', 'encode-hevc', 'encoder-bringup', 'gpu-compute', 'metal-suite']
    catalog = call('list')
    assert [r['id'] for r in catalog] == ids
    assert all(not r['available'] and r['unavailable_reason'] and not r['needs_root'] for r in catalog)
    assert catalog[0]['params'] == [
        {'key': 'size', 'label': 'Size', 'type': 'choice', 'default': '1080p', 'choices': ['720p', '1080p', '1440p']},
        {'key': 'pattern', 'label': 'Pattern', 'type': 'choice', 'default': 'motion', 'choices': ['static', 'motion', 'edges', 'noise', 'cuts']},
        {'key': 'bitrate_mbps', 'label': 'Bitrate (Mbit/s)', 'type': 'int', 'default': 8, 'min': 1, 'max': 100},
        {'key': 'seconds', 'label': 'Length (s)', 'type': 'int', 'default': 6, 'min': 2, 'max': 60}]
    assert call('run', 'encode-h264')['status'] == 'skip'
    assert call('run-all') == []
    assert call('run', 'bogus')['status'] == 'error'
    assert call('run', r'\145ncode-h264')['status'] == 'error'
    assert call('run', 'bad"id\nwith controls\r')['status'] == 'error'
    assert call('run')['status'] == 'error'

    matrix = stub('nvenc_matrix', r'''
printf '%s\n' "$@" > "$TEST_TRACE"
[ "$NVENC_VT_VERBOSE" = 1 ] || exit 90
[ "$NVMTL_VT_RC" = 1 ] || exit 91
if [ "$1" = hevc ]; then [ "$NVMTL_NVENC_HEVC" = 1 ] || exit 92; fi
case $STUB_MODE in
  bar1) printf 'nve264: cpu map -> 0x51\nnve264: open: engine bring-up failed for 1920x1080\nnvenc-vt: StartSession 1920x1080: engine refused\nVTCompressionSessionCreate: OSStatus -12908\n' >&2; exit 1;;
  engine-used) echo 'engine already in use in this process: -12908' >&2; exit 1;;
  status-only) echo 'VTCompressionSessionCreate: OSStatus -12908' >&2; exit 1;;
  startup-json)
    echo 'VTCompressionSessionPrepareToEncodeFrames (StartSession): OSStatus -12908' >&2
    echo '{"sessions":[{"correct":false,"prepare_status":-12908}]}' > "${10}"
    echo 'SESSION 1 correct=0 encoded=0 decoded=0 rate=0.000 Mbps PSNR=0.00 min=0.00 p95=0.00 ms'
    exit 1;;
  skip) echo 'unsupported device'; exit 77;;
  execution-error) exit 127;;
  missing-session) echo 'no SESSION output'; exit 0;;
esac
for ((i=0;i<50;i++)); do echo "old output $i"; done
printf 'quote=" backslash=\\ tab=\t carriage=\r escape=\033 byte=\001 UTF-8=café\n' >&2
case $STUB_MODE in
  wrong) correct=0;; *) correct=1;;
esac
printf 'SESSION 1 correct=%s encoded=360 decoded=360 rate=10.199 Mbps PSNR=40.82 min=39.84 p95=7.27 ms\n' "$correct"
if [ "$STUB_MODE" != session-only ]; then
cat > "${10}" <<'JSON'
{"sessions": [{"correct": true, "encode_service_fps":
2.37e2, "latency_p95_ms": 7.271, "mean_y_psnr":40.8234, "steady_mbps":10.1991,
"encoded":360, "decoded":360, "min_y_psnr":39.84, "latency_p50_ms":4.2,
"mean_uv_psnr":44.5, "latency_max_ms":9.1, "encode_cpu_ms_frame":2.3}]}
JSON
fi
if [ "$STUB_MODE" = malformed-metrics ]; then
    echo '{"encode_service_fps": "NaN", "mean_y_psnr": null, "latency_p95_ms": "bad", "steady_mbps": 01}' > "${10}"
fi
[ "$STUB_MODE" != fail ] || exit 1
''')
    stub('encoder_bringup', 'printf "%s\\n" "$1" > "$TEST_TRACE"\n[ "$NVENC_VT_VERBOSE" = 1 ] || exit 90\necho "PASS: $1 encoder opened"\n')
    compute = stub('gpu_compute_check', 'echo "PASS: 4096 of 4096"\n')
    stub('test_metal_a', 'echo "probe output"\nexit 0\n')
    metal_fail = stub('test_metal_b', 'exit 1\n')
    metal_skip = stub('test_metal_c', 'exit 77\n')
    catalog = call('list')
    assert all(r['available'] and r['unavailable_reason'] is None for r in catalog)
    assert catalog[2]['params'][0]['choices'] == ['h264', 'hevc']

    result = call('run', 'encode-h264')
    assert result['status'] == 'pass' and result['hint'] is None
    assert result['metrics']['fps'] == 237 and result['metrics']['psnr_db'] == 40.8234
    assert result['metrics']['p95_ms'] == 7.271 and result['metrics']['bitrate_mbps'] == 10.1991
    assert result['metrics']['min_y_psnr'] == 39.84 and result['metrics']['latency_p50_ms'] == 4.2
    assert result['metrics']['encoded'] == 360 and '360 of 360 frames' in result['summary']
    assert len(result['details'].split('\n')) == 40
    assert 'old output 0\n' not in result['details'] and 'quote=" backslash=\\' in result['details']
    assert '\r' in result['details'] and '\x1b' in result['details'] and '\x01' in result['details'] and 'café' in result['details']
    assert trace.read_text().splitlines()[:9] == ['h264', '1920', '1080', '360', '60', '8000000', 'motion', '1', 'encode-h264']
    result = call('run', 'encode-hevc', '--param', 'size=1440p', '--param', 'pattern=cuts', '--param', 'bitrate_mbps=100', '--param', 'seconds=60')
    assert result['status'] == 'pass'
    assert trace.read_text().splitlines()[:9] == ['hevc', '2560', '1440', '3600', '60', '100000000', 'cuts', '1', 'encode-hevc']
    call('run', 'encode-h264', '--param', 'size=720p', '--param', 'bitrate_mbps=1', '--param', 'seconds=2')
    assert trace.read_text().splitlines()[1:6] == ['1280', '720', '120', '60', '1000000']
    assert call('run', 'encoder-bringup', '--param', 'codec=hevc')['status'] == 'pass'
    assert trace.read_text() == 'hevc\n'
    assert call('run', 'gpu-compute')['status'] == 'pass'
    assert call('run', 'encode-h264', mode='fail')['status'] == 'fail'
    assert call('run', 'encode-h264', mode='wrong')['status'] == 'fail'
    assert call('run', 'encode-h264', mode='missing-session')['status'] == 'fail'
    assert call('run', 'encode-h264', mode='skip')['status'] == 'skip'
    assert call('run', 'encode-h264', mode='execution-error')['status'] == 'error'
    result = call('run', 'encode-h264', mode='session-only')
    assert result['status'] == 'pass' and result['metrics']['p95_ms'] == 7.27 and 'fps' not in result['metrics']
    hint = "The card's BAR1 window is full: quit other GPU apps or restart the Mac, then run again."
    for mode in ('bar1', 'engine-used'):
        result = call('run', 'encode-h264', mode=mode)
        assert result['status'] == 'fail' and result['hint'] == hint and '-12908' in result['details']
    assert call('run', 'encode-h264', mode='status-only')['hint'] is None
    result = call('run', 'encode-h264', mode='startup-json')
    assert result['status'] == 'fail' and result['metrics']['prepare_status'] == -12908
    assert 'OSStatus -12908' in result['details'] and result['hint'] is None
    result = call('run', 'encode-h264', mode='malformed-metrics')
    assert 'fps' not in result['metrics'] and result['metrics']['psnr_db'] == 40.82
    assert result['metrics']['p95_ms'] == 7.27 and result['metrics']['bitrate_mbps'] == 10.199

    prior = trace.read_text()
    for args in [
        ('--param', 'unknown=x'), ('--param', 'size=4k'), ('--param', 'pattern=*'),
        ('--param', 'pattern=static,motion'), ('--param', 'pattern='), ('--param', 'seconds=1'),
        ('--param', 'seconds=61'), ('--param', 'seconds=-1'), ('--param', 'seconds=02'),
        ('--param', 'seconds=2.0'), ('--param', 'seconds=999999999999999999999999'),
        ('--param', 'bitrate_mbps=0'), ('--param', 'bitrate_mbps=101'),
        ('--param', 'size'), ('--param',), ('--bogus',), ('--param', 'seconds=2', 'extra'),
    ]:
        assert call('run', 'encode-h264', *args)['status'] == 'error', args
    assert trace.read_text() == prior, 'invalid params launched the program'
    assert call('run', 'gpu-compute', '--param', 'codec=h264')['status'] == 'error'
    assert call('run', 'encoder-bringup', '--param', 'codec=av1')['status'] == 'error'
    # Parameter errors take precedence over missing executables.
    compute.chmod(0o644)
    assert call('run', 'gpu-compute', '--param', 'bad=x')['status'] == 'error'
    assert call('run', 'gpu-compute')['status'] == 'skip'
    compute.chmod(0o755)
    failure = subprocess.run([str(cli), 'test', 'run', 'gpu-compute', '--json'],
                             env=dict(env, TMPDIR=str(Path(tmp) / 'nonexistent')), capture_output=True, text=True)
    assert failure.returncode != 0 and 'cannot create test temporary directory' in failure.stderr

    result = call('run', 'metal-suite')
    assert result['status'] == 'fail' and result['summary'] == '1 of 3 passed'
    assert result['metrics'] == {'passed': 1, 'failed': 1, 'skipped': 1, 'total': 3}
    assert result['details'].splitlines() == ['test_metal_a: PASS', 'test_metal_b: FAIL', 'test_metal_c: SKIP']
    metal_fail.unlink()
    assert call('run', 'metal-suite')['status'] == 'pass'
    (tests / 'test_metal_a').unlink()
    assert call('run', 'metal-suite')['status'] == 'skip'
    metal_skip.chmod(0o644)
    assert not call('list')[-1]['available']
    metal_skip.chmod(0o755)
    stub('test_metal_a', 'exit 0\n')
    results = call('run-all')
    assert [r['id'] for r in results] == ids and all(r['status'] == 'pass' for r in results)
    matrix.unlink()
    assert [r['id'] for r in call('run-all')] == ids[2:]
    assert not call('list')[0]['available']
    assert call('run', 'encode-h264')['status'] == 'skip'
    assert 'gpu-compute: pass' in call('run', 'gpu-compute', json_output=False)

    # Bundle lookup: both Resources/nvmtlctl and Contents/MacOS/nvmtlctl layouts.
    bundle = Path(tmp) / 'GPU Control.app/Contents'
    resources = bundle / 'Resources'
    resources.mkdir(parents=True)
    shutil.copytree(tests, resources / 'Tests')
    for folder in (resources, bundle / 'MacOS'):
        folder.mkdir(exist_ok=True)
        bundled = folder / 'nvmtlctl'
        shutil.copyfile(cli, bundled)
        bundled.chmod(0o755)
        override = env.pop('NVMTL_TESTS_DIR')
        assert call('list', binary=bundled)[3]['available']
        env['NVMTL_TESTS_DIR'] = override
        # Override wins, including its missing encoder; no mixed-directory fallback.
        assert not call('list', binary=bundled)[0]['available']

    # Catalog metadata is read from the manifest, rather than hardcoded into the CLI.
    text = (tests / 'manifest.tsv').read_text().replace('H.264 encode\t', 'Changed title\t').replace('int\t8\t-\t1\t100', 'int\t9\t-\t1\t100')
    (tests / 'manifest.tsv').write_text(text)
    catalog = call('list')
    assert catalog[0]['title'] == 'Changed title' and catalog[0]['params'][2]['default'] == 9
print(f'PASS: {checks} CLI invocations; JSON contract, failures, metrics, parameters, suite, lookup and bundle parity')
PY
