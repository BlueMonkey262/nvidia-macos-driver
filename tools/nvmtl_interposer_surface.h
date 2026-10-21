// Link the matching dylib into each probe so interposition also covers a later dlopen.
#pragma once
#include <IOSurface/IOSurface.h>
#include <stdatomic.h>

extern _Atomic int nvmtl_seed_fail_unlock, nvmtl_seed_omit_unlock_seed;
extern IOSurfaceRef nvmtl_seed_fault_surface;

extern __thread unsigned nvmtl_wait_observe_events, nvmtl_wait_event_fault;
extern __thread unsigned nvmtl_wait_event_queries, nvmtl_wait_event_retries, nvmtl_wait_event_faults;
extern __thread unsigned nvmtl_wait_policy_errors;
extern int (*nvmtl_wait_state)(void);
