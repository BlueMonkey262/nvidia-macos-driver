#!/usr/bin/env python3
"""Compile production pool configuration; verify parsing, diagnostics and concurrent once initialization."""
import os
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
src = (root / 'plugin/nvmtl_vk.c').read_text()
a = src.index('#define NVMTL_KEEP 256')
helper = src[a:src.index('static pthread_mutex_t g_keep_lock', a)]
fixture = r'''
#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static atomic_int go;
static int invalid_logs, state_logs;
static char state[1024];
static void nvlog(const char *fmt, ...) {
    char buf[1024]; va_list ap; va_start(ap, fmt); vsnprintf(buf, sizeof buf, fmt, ap); va_end(ap);
    if (strstr(buf, "invalid NVMTL_POOL_KEEP")) {
        invalid_logs++;
        assert(strstr(buf, "expected 0..256") && strstr(buf, "using default 16"));
    } else { state_logs++; snprintf(state, sizeof state, "%s", buf); }
}
static unsigned expected_limit; static int expected_on;
'''
checks = r'''
static void *worker(void *unused) {
    (void)unused;
    while (!atomic_load(&go)) sched_yield();
    for (int i = 0; i < 100; i++) {
        assert(nvmtl_keep_limit() == expected_limit);
        assert(nvmtl_keep_on() == expected_on);
    }
    return NULL;
}
int main(int argc, char **argv) {
    assert(argc == 4);
    expected_limit = (unsigned)strtoul(argv[1], NULL, 10); expected_on = atoi(argv[2]);
    pthread_t t[16];
    for (int i = 0; i < 16; i++) assert(!pthread_create(&t[i], NULL, worker, NULL));
    atomic_store(&go, 1);
    for (int i = 0; i < 16; i++) assert(!pthread_join(t[i], NULL));
    assert(invalid_logs == atoi(argv[3]) && state_logs == 1);
    assert(strstr(state, expected_on ? "pool reuse ON" : "pool reuse OFF"));
    if (expected_on) {
        char limit[80]; snprintf(limit, sizeof limit, "<= %u, NVMTL_POOL_KEEP", expected_limit);
        assert(strstr(state, limit));
    }
    assert(!setenv("NVMTL_POOL_KEEP", "123", 1)); /* config is process-lifetime, not re-read */
    assert(nvmtl_keep_limit() == expected_limit && nvmtl_keep_on() == expected_on);
    assert(state_logs == 1);
}
'''
cases = [(None,16,1,0), ('0',0,0,0), ('1',1,1,0), ('16',16,1,0), ('256',256,1,0),
         ('-1',16,1,1), ('257',16,1,1), ('',16,1,1), ('abc',16,1,1), ('16x',16,1,1),
         ('16 ',16,1,1), (' ',16,1,1), ('99999999999999999999999999999',16,1,1),
         ('-99999999999999999999999999999',16,1,1)]
with tempfile.TemporaryDirectory(prefix='nvmtl-keep-') as tmp:
    c = pathlib.Path(tmp) / 'test.c'
    exe = pathlib.Path(tmp) / 'test'
    c.write_text(fixture + helper + checks)
    subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-pthread', str(c), '-o', str(exe)], check=True)
    base = {k: v for k, v in os.environ.items() if k not in ('NVMTL_POOL_KEEP','NVMTL_POOL_REUSE','NVMTL_NO_POOL_REUSE')}
    for value, limit, enabled, invalid in cases:
        env = base.copy()
        if value is not None:
            env['NVMTL_POOL_KEEP'] = value
        subprocess.run([str(exe), str(limit), str(enabled), str(invalid)], env=env, check=True, timeout=10)
    for name, value in [('NVMTL_POOL_REUSE','0'), ('NVMTL_NO_POOL_REUSE','1')]:
        subprocess.run([str(exe), '16', '0', '0'], env={**base, name:value}, check=True, timeout=10)
print('PASS: 16 fresh-process configurations, invalid defaults/logs, zero disables, concurrent once initialization')
