// Link the matching dylib into each probe so interposition also covers a later dlopen.
#pragma once
#include <IOSurface/IOSurface.h>
#include <stdatomic.h>

extern _Atomic int nvmtl_seed_fail_unlock, nvmtl_seed_omit_unlock_seed;
extern IOSurfaceRef nvmtl_seed_fault_surface;
