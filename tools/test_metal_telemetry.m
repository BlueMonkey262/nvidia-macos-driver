// Telemetry transport/schema smoke test; no Metal methods are changed by this feature.
// Build: clang -fobjc-arc -Wall -Wextra -framework Foundation tools/test_metal_telemetry.m -o .scratch/test_metal_telemetry
// Run from repo root after building tools/gpu_telemetry: .scratch/test_metal_telemetry
// Exit: 0 pass, 1 fail, 77 skip (RM/device not available, after checking error JSON).
// Copyright (c) 2026 BlueMonkey
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <signal.h>

static int failures;
static void expect(BOOL ok, NSString *what)
{
    if (!ok) { fprintf(stderr, "FAIL %s\n", what.UTF8String); failures++; }
}

static NSDictionary *run(NSString *path, NSArray<NSString *> *args, int expectedStatus)
{
    char filename[] = ".scratch/telemetry-test.XXXXXX";
    int fd = mkstemp(filename);
    if (fd < 0) { expect(NO, @"mkstemp in .scratch"); return nil; }
    unlink(filename);
    NSFileHandle *file = [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:path];
    task.arguments = args;
    task.standardOutput = file;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) { expect(NO, error.localizedDescription); return nil; }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
    while (task.running && deadline.timeIntervalSinceNow > 0) [NSThread sleepForTimeInterval:0.05];
    if (task.running) {
        kill(task.processIdentifier, SIGKILL);
        expect(NO, @"probe/CLI exceeded 20 seconds");
        return nil;
    }
    [task waitUntilExit];
    expect(task.terminationReason == NSTaskTerminationReasonExit, @"normal exit");
    expect(task.terminationStatus == expectedStatus, @"expected exit status");
    [file seekToFileOffset:0];
    NSData *bytes = [file readDataToEndOfFile];
    if (expectedStatus != 0) return nil;
    id object = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:&error];
    expect([object isKindOfClass:NSDictionary.class], @"exactly one JSON object, no stdout logs");
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

static BOOL validate(NSDictionary *sample)
{
    if (!sample) return NO;
    expect([sample[@"schema_version"] isEqual:@1], @"schema version");
    expect([sample[@"timestamp_unix_s"] isKindOfClass:NSNumber.class], @"sample timestamp");
    expect([sample[@"probe"] isEqual:@"complete"], @"probe completed before alarm");
    NSArray *metrics = @[@"temperature_core_c", @"temperature_memory_c", @"temperature_hotspot_c",
        @"fan_rpm_slots", @"fan_percent", @"clock_graphics_mhz", @"clock_memory_mhz", @"clock_video_mhz",
        @"clock_graphics_max_mhz", @"clock_memory_max_mhz", @"clock_video_max_mhz", @"clock_pmumon",
        @"power_draw_w", @"power_limit_w", @"performance_state", @"gpu_utilization_percent",
        @"memory_utilization_percent", @"vram_total_bytes", @"vram_used_bytes", @"vram_free_bytes",
        @"bar1_total_bytes", @"bar1_used_bytes", @"bar1_free_bytes", @"bar1_grant_mapped_bytes",
        @"bar1_grant_budget_bytes", @"pcie_generation", @"pcie_width", @"driver_version",
        @"gsp_firmware_version", @"vbios_version", @"gpu_name", @"gpu_uuid", @"process_vram", @"nvrm_clients_by_pid"];
    for (NSString *key in metrics) {
        id value = sample[key];
        expect(value != nil && value != NSNull.null, [@"metric or explicit error: " stringByAppendingString:key]);
        if ([value isKindOfClass:NSDictionary.class] && value[@"error"])
            expect(value[@"domain"] != nil, [@"error domain: " stringByAppendingString:key]);
    }
    for (NSString *key in @[@"rm_cleanup", @"connection_close", @"fd_close", @"rusd_unmap", @"rusd_rm_unmap", @"rusd_close", @"rusd_fd_close"])
        expect(sample[key] == nil, [@"successful cleanup: " stringByAppendingString:key]);
    for (NSString *prefix in @[@"vram", @"bar1"]) {
        id total = sample[[prefix stringByAppendingString:@"_total_bytes"]];
        id used = sample[[prefix stringByAppendingString:@"_used_bytes"]];
        id free = sample[[prefix stringByAppendingString:@"_free_bytes"]];
        if ([total isKindOfClass:NSNumber.class] && [used isKindOfClass:NSNumber.class] && [free isKindOfClass:NSNumber.class])
            expect([used unsignedLongLongValue] + [free unsignedLongLongValue] == [total unsignedLongLongValue], @"memory accounting");
    }
    return [sample[@"setup"] isEqual:@"ok"];
}

int main(void)
{
    @autoreleasepool {
        NSError *error = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtPath:@".scratch" withIntermediateDirectories:YES attributes:nil error:&error]) {
            fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1;
        }
        NSString *root = [NSFileManager defaultManager].currentDirectoryPath;
        NSString *probe = [root stringByAppendingPathComponent:@"tools/gpu_telemetry"];
        NSString *cli = [root stringByAppendingPathComponent:@"tools/nvmtlctl"];
        BOOL available = NO;
        for (int i = 0; i < 3; i++) available |= validate(run(probe, @[], 0));
        validate(run(cli, @[@"telemetry", @"--json"], 0));
        validate(run(cli, @[@"--json", @"telemetry"], 0));
        run(cli, @[@"telemetry"], 2);
        run(cli, @[@"telemetry", @"--json", @"unexpected"], 2);
        if (failures) return 1;
        puts(available ? "PASS telemetry schema, repeated calls, cleanup, CLI argument handling" : "SKIP card unavailable; error JSON and CLI checks passed");
        return available ? 0 : 77;
    }
}
