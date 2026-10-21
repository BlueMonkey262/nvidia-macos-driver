// Telemetry transport/schema smoke test; no Metal methods are changed by this feature.
// Build: clang -fobjc-arc -Wall -Wextra -framework Foundation tools/test_metal_telemetry.m -o .scratch/test_metal_telemetry
// Run from repo root after building tools/gpu_telemetry: .scratch/test_metal_telemetry
// When the card is up, also runs --poll and --stream (3 live lines in 4s, SIGTERM within 1s).
// Exit: 0 pass, 1 fail, 77 skip (RM/device not available, after checking error JSON).
// Copyright (c) 2026 BlueMonkey
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <signal.h>
#include <fcntl.h>
#include <poll.h>
#include <errno.h>
#include <dispatch/dispatch.h>

static int failures;
static void expect(BOOL ok, NSString *what)
{
    if (!ok) { fprintf(stderr, "FAIL %s\n", what.UTF8String); failures++; }
}

static NSDictionary *run(NSString *path, NSArray<NSString *> *args, int expectedStatus, NSTimeInterval limit)
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
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:limit];
    while (task.running && deadline.timeIntervalSinceNow > 0) [NSThread sleepForTimeInterval:0.05];
    if (task.running) {
        kill(task.processIdentifier, SIGKILL);
        expect(NO, @"probe/CLI exceeded its deadline");
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
    if ([sample[@"setup"] isEqual:@"ok"]) {
        id rusd = sample[@"rusd"];
        if ([rusd isKindOfClass:NSDictionary.class] && [rusd[@"error"] isEqual:@46])
            expect(NO, [NSString stringWithFormat:@"rusd still INVALID_LIMIT 46 call=%@", rusd[@"call"] ?: @"missing"]);
    }
    return [sample[@"setup"] isEqual:@"ok"];
}

// Prints whether --poll produced numbers. A remaining error is a result, not a schema failure,
// unless it is still RM INVALID_LIMIT 46 (the map-length bug).
static void printDecode(NSString *label, NSDictionary *sample)
{
    fprintf(stderr, "%s setup=%s\n", label.UTF8String, [sample[@"setup"] description].UTF8String);
    for (NSString *key in @[@"rusd", @"rusd_poll", @"clock_graphics_mhz", @"clock_memory_mhz", @"clock_video_mhz",
            @"fan_rpm_slots", @"power_draw_w", @"power_average_w", @"power_limit_w",
            @"gpu_utilization_percent", @"memory_utilization_percent"]) {
        id value = sample[key];
        const char *shown = value ? [value description].UTF8String : "missing";
        fprintf(stderr, "  %s: %s\n", key.UTF8String, shown);
    }
}

static BOOL liveSample(NSDictionary *sample)
{
    if (![sample[@"schema_version"] isEqual:@1]) return NO;
    for (NSString *key in @[@"clock_graphics_mhz", @"clock_memory_mhz", @"clock_video_mhz",
            @"power_draw_w", @"power_limit_w", @"gpu_utilization_percent", @"memory_utilization_percent"])
        if (![sample[key] isKindOfClass:NSNumber.class]) return NO;
    NSArray *fan = sample[@"fan_rpm_slots"];
    if (![fan isKindOfClass:NSArray.class]) return NO;
    BOOL spinning = NO;
    for (id rpm in fan)
        if ([rpm isKindOfClass:NSNumber.class] && [rpm doubleValue] > 0) spinning = YES;
    if (!spinning) return NO;
    if (![sample[@"clock_sm_mhz"] isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *rusd = sample[@"rusd"];
    if (![rusd isKindOfClass:NSDictionary.class] || ![rusd[@"timestamps"] isKindOfClass:NSDictionary.class]) return NO;
    if (![sample[@"sample_index"] isKindOfClass:NSNumber.class]) return NO;
    return YES;
}

static void checkStream(NSString *probe)
{
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:probe];
    task.arguments = @[@"--stream"];
    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *inPipe = [NSPipe pipe]; // held open so stdin is not an immediate EOF
    task.standardOutput = outPipe;
    task.standardInput = inPipe;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) { expect(NO, error.localizedDescription); return; }
    int fd = outPipe.fileHandleForReading.fileDescriptor;
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    NSMutableData *acc = [NSMutableData data];
    NSMutableArray *lines = [NSMutableArray array];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:4];
    while (deadline.timeIntervalSinceNow > 0) {
        struct pollfd pfd = { .fd = fd, .events = POLLIN };
        poll(&pfd, 1, 100);
        uint8_t tmp[8192];
        ssize_t n = read(fd, tmp, sizeof tmp);
        if (n > 0) [acc appendBytes:tmp length:(NSUInteger)n];
        else if (n == 0) break;
        NSRange nl;
        while ((nl = [acc rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0 range:NSMakeRange(0, acc.length)]).location != NSNotFound) {
            NSData *piece = [acc subdataWithRange:NSMakeRange(0, nl.location)];
            [acc replaceBytesInRange:NSMakeRange(0, nl.location + 1) withBytes:NULL length:0];
            if (!piece.length) continue;
            id obj = [NSJSONSerialization JSONObjectWithData:piece options:0 error:NULL];
            if ([obj isKindOfClass:NSDictionary.class]) [lines addObject:obj];
        }
    }
    NSUInteger live = 0;
    NSNumber *prev = nil;
    BOOL indexOk = YES;
    for (NSDictionary *sample in lines) {
        if (liveSample(sample)) live++;
        NSNumber *idx = sample[@"sample_index"];
        if (![idx isKindOfClass:NSNumber.class] || (prev && idx.unsignedLongLongValue <= prev.unsignedLongLongValue))
            indexOk = NO;
        prev = [idx isKindOfClass:NSNumber.class] ? idx : prev;
    }
    expect(live >= 3, [NSString stringWithFormat:@"at least 3 live stream lines in 4s (got %lu of %lu)",
                       (unsigned long)live, (unsigned long)lines.count]);
    expect(indexOk && prev != nil, @"monotonic sample_index");
    NSDictionary *first = nil, *second = nil;
    for (NSDictionary *sample in lines) {
        if ([sample[@"sample_index"] isEqual:@1]) first = sample;
        if ([sample[@"sample_index"] isEqual:@2]) second = sample;
    }
    expect(first[@"gpu_name"] != nil && second != nil && second[@"gpu_name"] == nil, @"identity on line 1 only");
    expect(first[@"process_vram"] != nil && second != nil && second[@"process_vram"] == nil, @"process VRAM not on line 2");
    pid_t pid = task.processIdentifier;
    expect(kill(pid, 0) == 0, @"stream still running before SIGTERM");
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        [task waitUntilExit];
        dispatch_semaphore_signal(done);
    });
    kill(pid, SIGTERM);
    BOOL exited = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC))) == 0;
    if (!exited) kill(pid, SIGKILL);
    expect(exited, @"stream exited within 1s of SIGTERM");
    fprintf(stderr, "STREAM lines=%lu live=%lu\n", (unsigned long)lines.count, (unsigned long)live);
}

static void checkStreamUsage(NSString *cli)
{
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:cli];
    task.arguments = @[@"telemetry"];
    NSPipe *outPipe = [NSPipe pipe];
    task.standardOutput = outPipe;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) { expect(NO, error.localizedDescription); return; }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (task.running && deadline.timeIntervalSinceNow > 0) [NSThread sleepForTimeInterval:0.02];
    if (task.running) { kill(task.processIdentifier, SIGKILL); expect(NO, @"usage hung"); return; }
    [task waitUntilExit];
    expect(task.terminationStatus == 2, @"telemetry without --json/--stream is usage");
    NSData *bytes = [outPipe.fileHandleForReading readDataToEndOfFile];
    NSString *text = [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding] ?: @"";
    expect([text containsString:@"telemetry --stream"], @"usage documents telemetry --stream");
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
        for (int i = 0; i < 3; i++) available |= validate(run(probe, @[], 0, 20));
        validate(run(cli, @[@"telemetry", @"--json"], 0, 20));
        validate(run(cli, @[@"--json", @"telemetry"], 0, 20));
        run(cli, @[@"telemetry"], 2, 20);
        run(cli, @[@"telemetry", @"--json", @"unexpected"], 2, 20);
        checkStreamUsage(cli);
        if (available) {
            NSDictionary *polled = run(probe, @[@"--poll"], 0, 25);
            validate(polled);
            if (polled) printDecode(@"POLL", polled);
            else fprintf(stderr, "POLL: no JSON\n");
            checkStream(probe);
        }
        if (failures) return 1;
        puts(available ? "PASS telemetry schema, repeated calls, cleanup, CLI, poll and stream" : "SKIP card unavailable; error JSON and CLI checks passed");
        return available ? 0 : 77;
    }
}
