/*
 * NullMoth NVIDIA driver for macOS
 * Copyright (c) 2026 NullMoth Systems.
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once
#include <mach/mach.h>
#include <mach/mach_port.h>
#include <stdio.h>
#include <string.h>

/* IKOT_IOKIT_CONNECT's userspace ABI value; kern/ipc_kobject.h is not an SDK header. */
enum { NVMTL_KOBJECT_IOKIT_CONNECT = 29 };

/* No port rights are acquired by mach_port_names. Only its two VM arrays belong to us.
 * The description call stays in the kernel: a concurrently recycled name cannot make
 * us send an IOKit RPC to an unrelated userspace server. Never use the object address. */
static inline kern_return_t nvmtl_client_census_snapshot(char *out, size_t size)
{
    mach_port_name_array_t names = NULL; mach_port_type_array_t types = NULL;
    mach_msg_type_number_t nn = 0, nt = 0;
    mach_port_t task = mach_task_self();
    kern_return_t kr = mach_port_names(task, &names, &nn, &types, &nt);
    if (kr != KERN_SUCCESS) {
        snprintf(out, size, "ports=unknown connects=unknown mach_port_names=%d", kr);
        return kr;
    }
    struct { char name[128]; unsigned count; } classes[4] = {0};
    unsigned sends = 0, dead = 0, connects = 0, nvrm = 0, unknown = 0, other = 0, errors = 0;
    kern_return_t first_error = KERN_SUCCESS;
    for (mach_msg_type_number_t i = 0; i < nn && i < nt; i++) {
        if (types[i] & MACH_PORT_TYPE_DEAD_NAME) dead++;
        if (!(types[i] & MACH_PORT_TYPE_SEND)) continue;
        sends++;
        natural_t type = 0; mach_vm_address_t address = 0;
        kobject_description_t desc = {0};
        kr = mach_port_kobject_description(task, names[i], &type, &address, desc);
        if (kr != KERN_SUCCESS) {
            errors++; if (first_error == KERN_SUCCESS) first_error = kr;
            continue;
        }
        if (type != NVMTL_KOBJECT_IOKIT_CONNECT) continue;
        connects++;
        desc[sizeof desc - 1] = 0;
        desc[strcspn(desc, "(")] = 0; /* IORegistryEntry descriptions append their ID. */
        if (!desc[0]) { unknown++; continue; }
        if (!strcmp(desc, "NVRMUserClient") || !strcmp(desc, "IOAccelNVRMBridge")) nvrm++;
        unsigned j = 0;
        for (; j < 4; j++) {
            if (!classes[j].count) { snprintf(classes[j].name, sizeof classes[j].name, "%s", desc); break; }
            if (!strcmp(classes[j].name, desc)) break;
        }
        if (j < 4) classes[j].count++; else other++;
    }
    if (names) vm_deallocate(task, (vm_address_t)names, (vm_size_t)nn * sizeof *names);
    if (types) vm_deallocate(task, (vm_address_t)types, (vm_size_t)nt * sizeof *types);
    char byclass[192] = {0}; size_t at = 0;
    for (unsigned j = 0; j < 4 && classes[j].count; j++) {
        int n = snprintf(byclass + at, sizeof byclass - at, "%s%.32s:%u", j ? "," : "", classes[j].name, classes[j].count);
        if (n < 0 || (size_t)n >= sizeof byclass - at) break;
        at += (size_t)n;
    }
    snprintf(out, size, "ports=%u send=%u dead=%u connects=%u nvrm=%u errors=%u first=%d types=%u unknown=%u other=%u classes=[%s]",
             nn, sends, dead, connects, nvrm, errors, first_error, nt, unknown, other, byclass);
    return KERN_SUCCESS;
}
