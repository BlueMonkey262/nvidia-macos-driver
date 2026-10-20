#!/usr/bin/env python3
"""Exercise production inflight/quarantine ownership with fake Vulkan types; no GPU fault injection."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
vk = (root / 'plugin/nvmtl_vk.c').read_text()
events = (root / 'plugin/NVMTLEventSync.m').read_text()
start = vk.index('struct nvmtl_inflight {')
helper = vk[start:vk.index('void nvmtl_vk_gsub_nvk_stats', start)]
start = events.index('static int nvmtl_gsub_finish(')
finish = events[start:events.index('@interface NVMTLPendingSurfaceWrite', start)]
assert events.count('nvmtl_vk_inflight_quarantine(f);') == 3, 'ahead begin, direct begin/finish, ahead finish'
begin = vk[vk.index('int nvmtl_vk_submit_begin_at('):vk.index('int nvmtl_vk_submit_finish(')]
assert begin.index('f->fence = fence;') < begin.index('pvkQueueSubmit('), 'failed submit must preserve the created fence'
fixture = r'''
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <assert.h>
typedef struct { int unused; } nvk_cmdbuf;
typedef uintptr_t VkFence;
typedef struct { int begun; void *hold; } nvmtl_prologue;
typedef struct nvmtl_inflight nvmtl_inflight;
typedef struct { nvmtl_inflight *inflight; } NVMTLSubmissionPart;
static atomic_uint gsub_inflight;
static int result;
static int nvmtl_vk_submit_finish(nvmtl_inflight *f) { assert(f); return result; }
'''
checks = r'''
int main(void) {
    for (int i = 0; i < 8; i++) {
        nvmtl_inflight *f = nvmtl_vk_inflight_new(); assert(f);
        f->fence = 100 + i; f->pre.begun = 1; f->pre.hold = (void *)(uintptr_t)(200 + i);
        NVMTLSubmissionPart part = { f };
        atomic_store(&gsub_inflight, 1); result = -2;
        assert(nvmtl_gsub_finish(&part) == -2);
        assert(!part.inflight && !atomic_load(&gsub_inflight));
        assert(g_inflight_quarantine == f && f->fence == (VkFence)(100 + i));
        assert(f->pre.begun && f->pre.hold == (void *)(uintptr_t)(200 + i));
    }
    unsigned n = 0;
    for (nvmtl_inflight *f = g_inflight_quarantine; f; f = f->next) n++;
    assert(n == 8);
    NVMTLSubmissionPart part = { nvmtl_vk_inflight_new() };
    atomic_store(&gsub_inflight, 1); result = 0;
    assert(!nvmtl_gsub_finish(&part) && !part.inflight && !atomic_load(&gsub_inflight));
    /* Test-only teardown: no actual GPU owns these fake handles. Production deliberately keeps them. */
    while (g_inflight_quarantine) {
        nvmtl_inflight *f = g_inflight_quarantine; g_inflight_quarantine = f->next; nvmtl_vk_inflight_free(f);
    }
}
'''
with tempfile.TemporaryDirectory(prefix='nvmtl-inflight-') as tmp:
    c = pathlib.Path(tmp) / 'test.c'
    exe = pathlib.Path(tmp) / 'test'
    c.write_text(fixture + helper + finish + checks)
    subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-pthread', str(c), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
print('PASS: failed inflights retain fences/prologues in quarantine; completed inflights free (fake Vulkan)')
