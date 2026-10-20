#!/usr/bin/env python3
"""Compile the production FC-entry wrapper with a concurrent fake translator (no Metal SDK)."""
import pathlib
import re
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
src = (root / 'plugin/NVMTLLibraryLoad.m').read_text()
start = src.index('static pthread_mutex_t g_fc_translate_lock')
wrapper = src[start:src.index('static nvmtl_refl_fn xlate_refl;', start)]
assert len(re.findall(r'\bxlate_fc\(', src)) == 1, 'all FC translator calls must use the leaf wrapper'
assert len(re.findall(r'\bnvmtl_xlate_fc_serial\(', src)) == 3, 'wrapper plus both entry sites'
fixture = r'''
#define _DEFAULT_SOURCE
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stddef.h>
#include <assert.h>
#include <unistd.h>
static atomic_int active, calls;
static int xlate_fc(const char *ll, const char *stage, const uint32_t *idx, const uint32_t *sizes,
                    const uint8_t *const *pay, size_t n, uint8_t **out, size_t *len, char *err, size_t cap) {
    (void)ll; (void)stage; (void)idx; (void)sizes; (void)pay; (void)n; (void)out; (void)len; (void)err; (void)cap;
    assert(atomic_fetch_add(&active, 1) == 0);
    usleep(1000);
    int r = atomic_fetch_add(&calls, 1) & 1; /* errors must also release the lock */
    assert(atomic_fetch_sub(&active, 1) == 1);
    return r;
}
'''
checks = r'''
static void *worker(void *unused) {
    (void)unused;
    for (int i = 0; i < 16; i++) {
        int r = nvmtl_xlate_fc_serial("air", "kernel", NULL, NULL, NULL, 0, NULL, NULL, NULL, 0);
        assert(r == 0 || r == 1);
    }
    return NULL;
}
int main(void) {
    pthread_t t[8];
    for (int i = 0; i < 8; i++) assert(!pthread_create(&t[i], NULL, worker, NULL));
    for (int i = 0; i < 8; i++) assert(!pthread_join(t[i], NULL));
    assert(atomic_load(&calls) == 128 && !atomic_load(&active));
}
'''
with tempfile.TemporaryDirectory(prefix='nvmtl-fc-') as tmp:
    c = pathlib.Path(tmp) / 'test.c'
    exe = pathlib.Path(tmp) / 'test'
    c.write_text(fixture + wrapper + checks)
    subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-pthread', str(c), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True, timeout=10)
print('PASS: both production FC sites serialize; success/error paths unlock (fake translator)')
