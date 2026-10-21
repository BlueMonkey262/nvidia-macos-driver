// NVK's selector-6 wait uses IOConnectCallScalarMethod; load this interposer as a linked dylib.
#include "nvmtl_interposer_surface.h"
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

__thread unsigned nvmtl_wait_observe_events, nvmtl_wait_event_fault;
__thread unsigned nvmtl_wait_event_queries, nvmtl_wait_event_retries, nvmtl_wait_event_faults;
__thread unsigned nvmtl_wait_policy_errors;
int (*nvmtl_wait_state)(void);
static kern_return_t (*original_scalar)(mach_port_t, uint32_t, const uint64_t *, uint32_t, uint64_t *, uint32_t *);
static kern_return_t probe_scalar(mach_port_t, uint32_t, const uint64_t *, uint32_t, uint64_t *, uint32_t *);
static pthread_once_t scalar_once = PTHREAD_ONCE_INIT;
static __thread int in_scalar;
static void resolve_scalar(void) {
    original_scalar = dlsym(RTLD_NEXT, "IOConnectCallScalarMethod");
    if (!original_scalar || original_scalar == probe_scalar) {
        fprintf(stderr, "FAIL resolve original IOConnectCallScalarMethod\n"); exit(1);
    }
}
static kern_return_t probe_scalar(mach_port_t connection, uint32_t selector, const uint64_t *input,
                                  uint32_t inputCount, uint64_t *output, uint32_t *outputCount) {
    if (in_scalar) { fprintf(stderr, "FAIL recursive IOConnectCallScalarMethod interposition\n"); exit(1); }
    in_scalar = 1; pthread_once(&scalar_once, resolve_scalar);
    if (nvmtl_wait_observe_events && selector == 6 && input && inputCount == 2) {
        if (nvmtl_wait_state && nvmtl_wait_state() != 1) nvmtl_wait_policy_errors++;
        if (!input[1]) nvmtl_wait_event_queries++;
        if (input[1] == 200) nvmtl_wait_event_retries++;
        if ((nvmtl_wait_event_fault == 1 && !input[1]) || (nvmtl_wait_event_fault == 2 && input[1] == 200)) {
            nvmtl_wait_event_fault = 0; nvmtl_wait_event_faults++;
            nvmtl_wait_event_queries = nvmtl_wait_event_retries = 0;
            in_scalar = 0; return kIOReturnError;
        }
    }
    kern_return_t rc = original_scalar(connection, selector, input, inputCount, output, outputCount);
    in_scalar = 0; return rc;
}
__attribute__((used)) static const struct { const void *replacement, *original; } interpose_scalar
    __attribute__((section("__DATA,__interpose"))) = {(const void *)probe_scalar, (const void *)IOConnectCallScalarMethod};
