#!/usr/bin/env python3
"""Run production map logging/census with a fake mapper: throttle, fields and concurrent totals."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
src = (root / 'plugin/nvmtl_vk.c').read_text()
a = src.index('static _Atomic uint64_t g_own_maps')
helper = src[a:src.index('#define NVMTL_POOL_BLOCK', a)]
a = src.index('    if (host_visible) { VkResult mr_ = pvkMapMemory(')
body = src[a:src.index('    g_alloc_bytes += mr.size;', a)]
fixture = r'''
#include <assert.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <pthread.h>
typedef int VkResult;
#define VK_WHOLE_SIZE (~0ull)
#define VK_SUCCESS 0
static uint64_t g_buf_made = 10, g_buf_gone = 3;
static size_t g_alloc_bytes = 1234;
static int g_dev;
static _Thread_local int map_result;
static pthread_mutex_t log_lock = PTHREAD_MUTEX_INITIALIZER;
static unsigned failures, running;
static unsigned failure_at[16];
static _Thread_local unsigned attempt;
static int pvkMapMemory(int dev, int mem, int off, uint64_t size, int flags, void **out) {
    (void)dev; (void)mem; (void)off; (void)size; (void)flags; (void)out;
    return map_result;
}
static void nvlog(const char *fmt, ...) {
    char buf[2048]; va_list ap; va_start(ap, fmt); vsnprintf(buf, sizeof buf, fmt, ap); va_end(ap);
    pthread_mutex_lock(&log_lock);
    if (strstr(buf, "vkMapMemory")) {
        assert(strstr(buf, "-> -5 for a 4096 byte buffer with 7 buffers live (10 made, 3 gone), 1234 bytes allocated, memory type 2"));
        assert(strstr(buf, "own CPU maps (failed): 0 made, by size <=4 MiB 0, <=16 MiB 0, <=64 MiB 0, larger 0"));
        assert(failures < 16); failure_at[failures++] = attempt;
    } else { assert(strstr(buf, "own CPU maps (running):")); running++; }
    pthread_mutex_unlock(&log_lock);
}
'''
probe = r'''
static int probe(size_t size, int result) {
    struct { uint64_t size; } mr = { size };
    struct { int mem; void *map; } storage = {0}, *out = &storage;
    int host_visible = 1, mt = 2;
    map_result = result;
'''
checks = r'''
    return 0;
}
static void *worker(void *arg) {
    uintptr_t bucket = (uintptr_t)arg;
    size_t sizes[] = {4u<<20,16u<<20,64u<<20,(64u<<20)+1};
    for (int i = 0; i < 1024; i++) assert(!probe(sizes[bucket], 0));
    return NULL;
}
int main(void) {
    for (attempt = 1; attempt <= 1536; attempt++) assert(probe(4096, -5) == -1);
    assert(failures == 11 && !running && atomic_load(&g_own_map_failures) == 1536);
    for (unsigned i = 0; i < 8; i++) assert(failure_at[i] == i + 1);
    assert(failure_at[8] == 512 && failure_at[9] == 1024 && failure_at[10] == 1536);
    pthread_t threads[4];
    for (uintptr_t i = 0; i < 4; i++) assert(!pthread_create(&threads[i], NULL, worker, (void *)i));
    for (int i = 0; i < 4; i++) assert(!pthread_join(threads[i], NULL));
    assert(atomic_load(&g_own_maps) == 4096 && running == 8);
    for (int i = 0; i < 4; i++) assert(atomic_load(&g_own_map_size[i]) == 1024);
}
'''
with tempfile.TemporaryDirectory(prefix='nvmtl-map-') as tmp:
    c = pathlib.Path(tmp) / 'test.c'
    exe = pathlib.Path(tmp) / 'test'
    c.write_text(fixture + helper + probe + body + checks)
    subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-pthread', str(c), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
print('PASS: failures 1..8/512/1024/1536 log once with all fields; concurrent census totals match (fake mapper)')
