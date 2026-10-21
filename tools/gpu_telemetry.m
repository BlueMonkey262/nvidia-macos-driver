/*
 * Read-only r610 RM telemetry probe. Requires NVIDIA open-gpu-kernel-modules 610.57.04 headers.
 * R=/path/to/open-gpu-kernel-modules-610.57.04
 * clang -fobjc-arc -Wall -Wextra -framework Foundation -framework IOKit \
 *   -I"$R/src/common/sdk/nvidia/inc" -I"$R/src/nvidia/arch/nvalloc/unix/include" \
 *   tools/gpu_telemetry.m -o tools/gpu_telemetry
 * ./tools/gpu_telemetry
 * ./tools/gpu_telemetry --poll
 *   Default is off and sends no poll request (alloc polledDataMask stays 0).
 *   --poll, after a successful class 0xde alloc, sends NV00DE_CTRL_CMD_REQUEST_DATA_POLL
 *   (0xde0001) for CLOCK|PERF|POWER|FAN, waits up to 2s for valid sequences, copies
 *   them, then frees the object so the firmware request ends with this client.
 *   It does not send REQUEST_POLL_INTERVAL (0xde0002). While the object is alive,
 *   GSP samples those sections at the driver's default interval (500 ms, or 100 ms
 *   on Tesla, unless RMRusdPollingInterval is set). That is one GSP RPC on request
 *   and another on free, and it can raise idle power or wake the GPU from a deeper
 *   idle until the object is freed. --poll uses a 17s alarm; the default stays 15s.
 * Copyright (c) 2026 BlueMonkey
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <stdint.h>
#include <fcntl.h>
#include <signal.h>
#include <stdatomic.h>
#include <unistd.h>
#include <errno.h>
#include <sys/sysctl.h>
#include <string.h>
#include <time.h>
#include <nvos.h>
#include <nv_escape.h>
#include <nv-unix-nvos-params-wrappers.h>
#include <class/cl0080.h>
#include <class/cl2080.h>
#include <class/cl00de.h>
#include <ctrl/ctrl0000/ctrl0000gpu.h>
#include <ctrl/ctrl0000/ctrl0000system.h>
#include <ctrl/ctrl2080/ctrl2080gpu.h>
#include <ctrl/ctrl2080/ctrl2080fb.h>
#include <ctrl/ctrl2080/ctrl2080bus.h>
#include <ctrl/ctrl2080/ctrl2080gsp.h>
#include <ctrl/ctrl2080/ctrl2080bios.h>
#include <ctrl/ctrl2080/ctrl2080thermal.h>
#include <ctrl/ctrl2080/ctrl2080perf.h>
#include <ctrl/ctrl2080/ctrl2080clk.h>
#include <ctrl/ctrl00de.h>

// The selector/open protocol is nvrm_xnu.c in nvk/nvk-macos.patch, not Apple's accelerator ABI.
enum { SelEsc = 1, SelBindFd = 3 };
static io_connect_t connection;
static int boundFd = -1;
static NvHandle client, device = 0x71000001, subdevice = 0x71000002;
static NSMutableDictionary *output;
static NSString *errorDomain = @"rm";
static char timeoutJSON[262144];
static volatile sig_atomic_t timeoutLength;

static int wantPoll;
static NSDictionary *failure(NvU32 status) { return @{@"error": @(status), @"domain": errorDomain}; }
static NSDictionary *failureCall(NvU32 status, NSString *call)
{
    return @{@"error": @(status), @"domain": errorDomain, @"call": call};
}
static NSDictionary *unavailable(NSString *why) { return @{@"error": why, @"domain": @"probe"}; }

static void timedOut(int sig)
{
    (void)sig;
    size_t off = 0, length = (size_t)timeoutLength;
    while (off < length) {
        ssize_t n = write(STDOUT_FILENO, timeoutJSON + off, length - off);
        if (n > 0) off += (size_t)n;
        else if (n < 0 && errno == EINTR) continue;
        else break;
    }
    _exit(0);
}

// Freeze a valid JSON snapshot before entering IOKit, including errors for queries not reached.
static void checkpoint(NSString *stage)
{
    output[@"stage"] = stage;
    output[@"probe"] = unavailable(@"timeout");
    NSData *data = [NSJSONSerialization dataWithJSONObject:output options:NSJSONWritingSortedKeys error:NULL];
    if (!data || data.length + 1 > sizeof timeoutJSON) return;
    sigset_t block, old;
    sigemptyset(&block); sigaddset(&block, SIGALRM);
    sigprocmask(SIG_BLOCK, &block, &old);
    memcpy(timeoutJSON, data.bytes, data.length);
    timeoutJSON[data.length] = '\n';
    timeoutLength = (sig_atomic_t)(data.length + 1);
    sigprocmask(SIG_SETMASK, &old, NULL);
}

static NvU32 escape(io_connect_t conn, NvU32 command, void *params, size_t size)
{
    checkpoint([NSString stringWithFormat:@"escape_0x%x", command]);
    uint64_t scalar = command;
    size_t outSize = size;
    kern_return_t kr = IOConnectCallMethod(conn, SelEsc, &scalar, 1, params, size,
                                         NULL, NULL, params, &outSize);
    errorDomain = @"iokit";
    if (kr != KERN_SUCCESS) return kr;
    if (outSize != size) return kIOReturnBadArgument;
    errorDomain = @"rm";
    return NV_OK;
}

static NvU32 allocObject(NvHandle parent, NvHandle *object, NvU32 cls, void *params, NvU32 size)
{
    NVOS21_PARAMETERS p = { .hRoot = client, .hObjectParent = parent, .hObjectNew = *object,
        .hClass = cls, .pAllocParms = params, .paramsSize = size, .status = NV_ERR_GENERIC };
    NvU32 st = escape(connection, NV_ESC_RM_ALLOC, &p, sizeof p);
    if (st != NV_OK) return st;
    if (p.status == NV_OK) *object = p.hObjectNew;
    return p.status;
}

static NvU32 control(NvHandle object, NvU32 command, void *params, NvU32 size)
{
    NVOS54_PARAMETERS p = { .hClient = client, .hObject = object, .cmd = command,
        .params = params, .paramsSize = size, .status = NV_ERR_GENERIC };
    NvU32 st = escape(connection, NV_ESC_RM_CONTROL, &p, sizeof p);
    return st == NV_OK ? p.status : st;
}
#define QUERY(object, command, params) control(object, command, &(params), sizeof(params))

static NvU32 openControl(io_connect_t *conn, int *fd)
{
    checkpoint(@"open");
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("NVAccel"));
    kern_return_t kr = kIOReturnNotFound;
    if (svc) {
        kr = IOServiceOpen(svc, mach_task_self(), 0x4e560000u, conn);
        IOObjectRelease(svc);
    }
    if (kr != KERN_SUCCESS) {
        svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("NVRM"));
        if (svc) {
            kr = IOServiceOpen(svc, mach_task_self(), 0, conn);
            IOObjectRelease(svc);
        }
    }
    errorDomain = @"iokit";
    if (kr != KERN_SUCCESS) return kr;
    *fd = open("/dev/null", O_RDONLY | O_CLOEXEC);
    if (*fd < 0) { errorDomain = @"posix"; return (NvU32)errno; }
    uint64_t scalar = (uint64_t)*fd;
    checkpoint(@"bind_fd");
    return IOConnectCallScalarMethod(*conn, SelBindFd, &scalar, 1, NULL, NULL);
}

static id textBytes(const void *bytes, size_t length)
{
    const char *p = bytes;
    return [[NSString alloc] initWithBytes:p length:strnlen(p, length) encoding:NSUTF8StringEncoding]
        ?: unavailable(@"invalid_utf8");
}

static void identity(void)
{
    NV2080_CTRL_GPU_GET_NAME_STRING_PARAMS name = {
        .gpuNameStringFlags = NV2080_CTRL_GPU_GET_NAME_STRING_FLAGS_TYPE_ASCII };
    NvU32 st = QUERY(subdevice, NV2080_CTRL_CMD_GPU_GET_NAME_STRING, name);
    output[@"gpu_name"] = st ? failure(st) : textBytes(name.gpuNameString.ascii, sizeof name.gpuNameString.ascii);
    NV2080_CTRL_GPU_GET_GID_INFO_PARAMS uuid = {0}; // ASCII SHA1 GPU UUID, per ctrl2080gpu.h.
    st = QUERY(subdevice, NV2080_CTRL_CMD_GPU_GET_GID_INFO, uuid);
    output[@"gpu_uuid"] = st ? failure(st) : (uuid.length <= sizeof uuid.data ?
        textBytes(uuid.data, uuid.length) : unavailable(@"invalid_length"));
    NV0000_CTRL_SYSTEM_GET_BUILD_VERSION_V2_PARAMS version = {0};
    st = QUERY(client, NV0000_CTRL_CMD_SYSTEM_GET_BUILD_VERSION_V2, version);
    output[@"driver_version"] = st ? failure(st) : textBytes(version.driverVersionBuffer, sizeof version.driverVersionBuffer);
    NV2080_CTRL_GSP_GET_FEATURES_PARAMS gsp = {0};
    st = QUERY(subdevice, NV2080_CTRL_CMD_GSP_GET_FEATURES, gsp);
    output[@"gsp_firmware_version"] = st ? failure(st) : (gsp.bValid ?
        textBytes(gsp.firmwareVersion, sizeof gsp.firmwareVersion) : unavailable(@"gsp_not_valid"));
    NV2080_CTRL_BIOS_GET_INFO_V2_PARAMS bios = { .biosInfoListSize = 2 };
    bios.biosInfoList[0].index = NV2080_CTRL_BIOS_INFO_INDEX_REVISION;
    bios.biosInfoList[1].index = NV2080_CTRL_BIOS_INFO_INDEX_OEM_REVISION;
    st = QUERY(subdevice, NV2080_CTRL_CMD_BIOS_GET_INFO_V2, bios);
    output[@"vbios_version"] = st ? failure(st) : [NSString stringWithFormat:@"%02X.%02X.%02X.%02X.%02X",
        (bios.biosInfoList[0].data >> 24) & 255, (bios.biosInfoList[0].data >> 16) & 255,
        (bios.biosInfoList[0].data >> 8) & 255, bios.biosInfoList[0].data & 255, bios.biosInfoList[1].data & 255];
    NV2080_CTRL_GPU_GET_INFO_V2_PARAMS info = { .gpuInfoListSize = 1 };
    info.gpuInfoList[0].index = NV2080_CTRL_GPU_INFO_INDEX_GPU_SM_VERSION;
    st = QUERY(subdevice, NV2080_CTRL_CMD_GPU_GET_INFO_V2, info);
    output[@"sm_version_raw"] = st ? failure(st) : @(info.gpuInfoList[0].data);
}

static id fbInfo(NvU32 index)
{
    NV2080_CTRL_FB_GET_INFO_V2_PARAMS p = { .fbInfoListSize = 1 };
    p.fbInfoList[0].index = index;
    NvU32 st = QUERY(subdevice, NV2080_CTRL_CMD_FB_GET_INFO_V2, p);
    return st ? failure(st) : @((uint64_t)p.fbInfoList[0].data * 1024ull);
}

static void memoryInfo(void)
{
    output[@"vram_total_bytes"] = fbInfo(NV2080_CTRL_FB_INFO_INDEX_TOTAL_RAM_SIZE);
    output[@"vram_heap_bytes"] = fbInfo(NV2080_CTRL_FB_INFO_INDEX_HEAP_SIZE);
    output[@"vram_free_bytes"] = fbInfo(NV2080_CTRL_FB_INFO_INDEX_HEAP_FREE);
    output[@"bar1_total_bytes"] = fbInfo(NV2080_CTRL_FB_INFO_INDEX_BAR1_SIZE);
    output[@"bar1_free_bytes"] = fbInfo(NV2080_CTRL_FB_INFO_INDEX_BAR1_AVAIL_SIZE);
    output[@"bar1_largest_free_bytes"] = fbInfo(NV2080_CTRL_FB_INFO_INDEX_BAR1_MAX_CONTIGUOUS_AVAIL_SIZE);
    for (NSString *prefix in @[@"vram", @"bar1"]) {
        id total = output[[prefix stringByAppendingString:@"_total_bytes"]];
        id free = output[[prefix stringByAppendingString:@"_free_bytes"]];
        output[[prefix stringByAppendingString:@"_used_bytes"]] =
            [total isKindOfClass:NSNumber.class] && [free isKindOfClass:NSNumber.class] &&
            [total unsignedLongLongValue] >= [free unsignedLongLongValue] ?
            @([total unsignedLongLongValue] - [free unsignedLongLongValue]) : unavailable(@"dependency_failed");
    }
}

static void linkInfo(void)
{
    NV2080_CTRL_BUS_GET_INFO_V2_PARAMS p = { .busInfoListSize = 1 };
    p.busInfoList[0].index = NV2080_CTRL_BUS_INFO_INDEX_PCIE_GPU_LINK_CTRL_STATUS;
    NvU32 st = QUERY(subdevice, NV2080_CTRL_CMD_BUS_GET_INFO_V2, p);
    output[@"pcie_generation"] = st ? failure(st) : @(DRF_VAL(2080_CTRL_BUS, _INFO, _PCIE_LINK_CTRL_STATUS_LINK_SPEED, p.busInfoList[0].data));
    output[@"pcie_width"] = st ? failure(st) : @(DRF_VAL(2080_CTRL_BUS, _INFO, _PCIE_LINK_CTRL_STATUS_LINK_WIDTH, p.busInfoList[0].data));
}

static NvU32 thermalInstruction(NV2080_CTRL_THERMAL_SYSTEM_INSTRUCTION *instruction)
{
    NV2080_CTRL_THERMAL_SYSTEM_EXECUTE_V2_PARAMS p = {
        .clientAPIVersion = THERMAL_SYSTEM_API_VER, .clientAPIRevision = THERMAL_SYSTEM_API_REV,
        .clientInstructionSizeOf = sizeof *instruction, .instructionListSize = 1 };
    p.instructionList[0] = *instruction;
    NvU32 st = QUERY(subdevice, NV2080_CTRL_CMD_THERMAL_SYSTEM_EXECUTE_V2, p);
    if (st) return st;
    *instruction = p.instructionList[0];
    if (!instruction->executed) return NV_ERR_INVALID_STATE;
    return instruction->result;
}

static void thermalInfo(void)
{
    NV2080_CTRL_THERMAL_SYSTEM_INSTRUCTION i = {
        .opcode = NV2080_CTRL_THERMAL_SYSTEM_GET_INFO_SENSORS_AVAILABLE_OPCODE };
    NvU32 st = thermalInstruction(&i);
    if (st) {
        output[@"thermal_sensors"] = failure(st);
        output[@"temperature_core_c"] = failure(st);
        output[@"temperature_memory_c"] = failure(st);
        return;
    }
    NvU32 count = i.operands.getInfoSensorsAvailable.availableSensors;
    NSMutableArray *sensors = [NSMutableArray array];
    output[@"thermal_sensors"] = sensors;
    if (count > 32) { output[@"thermal_sensors"] = unavailable(@"sensor_count_over_32"); return; }
    for (NvU32 sensor = 0; sensor < count; sensor++) {
        i = (NV2080_CTRL_THERMAL_SYSTEM_INSTRUCTION){
            .opcode = NV2080_CTRL_THERMAL_SYSTEM_GET_INFO_SENSOR_TARGET_OPCODE };
        i.operands.getInfoSensorTarget.sensorIndex = sensor;
        st = thermalInstruction(&i);
        if (st) { [sensors addObject:@{@"sensor": @(sensor), @"target": failure(st)}]; continue; }
        NvU32 targetIndex = i.operands.getInfoSensorTarget.targetIndex;
        i = (NV2080_CTRL_THERMAL_SYSTEM_INSTRUCTION){
            .opcode = NV2080_CTRL_THERMAL_SYSTEM_GET_INFO_TARGET_TYPE_OPCODE };
        i.operands.getInfoTargetType.targetIndex = targetIndex;
        st = thermalInstruction(&i);
        if (st) { [sensors addObject:@{@"sensor": @(sensor), @"target_type": failure(st)}]; continue; }
        NvU32 type = i.operands.getInfoTargetType.type;
        i = (NV2080_CTRL_THERMAL_SYSTEM_INSTRUCTION){
            .opcode = NV2080_CTRL_THERMAL_SYSTEM_GET_STATUS_SENSOR_READING_OPCODE };
        i.operands.getStatusSensorReading.sensorIndex = sensor;
        st = thermalInstruction(&i);
        id reading = st ? failure(st) : @(i.operands.getStatusSensorReading.value);
        [sensors addObject:@{@"sensor": @(sensor), @"target_type": @(type), @"temperature_c": reading}];
        if (type == NV2080_CTRL_THERMAL_SYSTEM_TARGET_GPU) output[@"temperature_core_c"] = reading;
        if (type == NV2080_CTRL_THERMAL_SYSTEM_TARGET_MEMORY) output[@"temperature_memory_c"] = reading;
    }
}

static void perfInfo(void)
{
    NV2080_CTRL_PERF_GET_CURRENT_PSTATE_PARAMS state = {0};
    NvU32 st = QUERY(subdevice, NV2080_CTRL_CMD_PERF_GET_CURRENT_PSTATE, state);
    NvU32 mask = state.currPstate;
    output[@"performance_state"] = st ? failure(st) :
        (mask && !(mask & (mask - 1)) && mask <= NV2080_CTRL_PERF_PSTATES_P15 ?
         (id)[NSString stringWithFormat:@"P%d", __builtin_ctz(mask)] : unavailable(@"invalid_pstate_mask"));
    NV2080_CTRL_CLK_PMUMON_CLK_DOMAINS_GET_SAMPLES_PARAMS clocks = {0};
    clocks.super.retrievalMode = NV2080_CTRL_PMUMON_RETRIEVAL_MODE_LATEST_SAMPLE_ONLY;
    st = QUERY(subdevice, NV2080_CTRL_CMD_CLK_PMUMON_CLK_DOMAINS_GET_SAMPLES, clocks);
    if (st) output[@"clock_pmumon"] = failure(st);
    else if (clocks.super.numSamples != 1) output[@"clock_pmumon"] = unavailable(@"no_single_latest_sample");
    else {
        NV2080_CTRL_CLK_PMUMON_CLK_DOMAINS_SAMPLE *c = &clocks.samples[0];
        output[@"clock_pmumon"] = @{@"gpu_timestamp_ns": @(c->super.timestamp), @"freshness": @"unverified"};
        NSArray *keys = @[@"clock_graphics_mhz", @"clock_memory_mhz", @"clock_video_mhz"];
        NvU32 values[] = { c->gpcClkFreqKHz, c->dramClkFreqKHz, c->nvdClkFreqKHz };
        for (int j = 0; j < 3; j++) output[keys[j]] = values[j] == NV2080_CTRL_CLK_PMUMON_CLK_DOMAINS_SAMPLE_INVALID ?
            unavailable(@"clock_domain_not_supported") : (id)@(values[j] / 1000.0);
    }
    // Public legacy ABI lacks domain enums and frequency units: retain raw data, do not guess MHz.
    NV2080_CTRL_PERF_GET_LEVEL_INFO_V2_PARAMS level = {
        .level = NV2080_CTRL_PERF_GET_LEVEL_INFO_LEVEL_STANDARD,
        .perfGetClkInfoListSize = NV2080_CTRL_PERF_CLK_MAX_DOMAINS };
    st = QUERY(subdevice, NV2080_CTRL_CMD_PERF_GET_LEVEL_INFO_V2, level);
    if (st) { output[@"clock_level_info_raw"] = failure(st); return; }
    if (level.perfGetClkInfoListSize > NV2080_CTRL_PERF_CLK_MAX_DOMAINS) {
        output[@"clock_level_info_raw"] = unavailable(@"invalid_domain_count"); return;
    }
    NSMutableArray *domains = [NSMutableArray array];
    for (NvU32 j = 0; j < level.perfGetClkInfoListSize; j++) {
        NV2080_CTRL_PERF_GET_CLK_INFO *c = &level.perfGetClkInfoList[j];
        [domains addObject:@{@"domain": @(c->domain), @"flags": @(c->flags), @"current": @(c->currentFreq),
            @"default": @(c->defaultFreq), @"min": @(c->minFreq), @"max": @(c->maxFreq)}];
    }
    output[@"clock_level_info_raw"] = domains;
}

static void processInfo(void)
{
    NV2080_CTRL_GPU_GET_PIDS_PARAMS pids = {
        .idType = NV2080_CTRL_GPU_GET_PIDS_ID_TYPE_CLASS, .id = NV20_SUBDEVICE_0,
        .pidTblCount = NV2080_CTRL_GPU_GET_PIDS_MAX_COUNT };
    NvU32 st = QUERY(subdevice, NV2080_CTRL_CMD_GPU_GET_PIDS, pids);
    if (st) { output[@"process_vram"] = failure(st); return; }
    if (pids.pidTblCount > NV2080_CTRL_GPU_GET_PIDS_MAX_COUNT) {
        output[@"process_vram"] = unavailable(@"invalid_pid_count"); return;
    }
    NSMutableArray *rows = [NSMutableArray array];
    output[@"process_vram"] = rows;
    for (NvU32 start = 0; start < pids.pidTblCount; start += NV2080_CTRL_GPU_GET_PID_INFO_MAX_COUNT) {
        NV2080_CTRL_GPU_GET_PID_INFO_PARAMS info = {0};
        info.pidInfoListCount = MIN(pids.pidTblCount - start, NV2080_CTRL_GPU_GET_PID_INFO_MAX_COUNT);
        for (NvU32 j = 0; j < info.pidInfoListCount; j++) {
            info.pidInfoList[j].pid = pids.pidTbl[start + j];
            info.pidInfoList[j].index = NV2080_CTRL_GPU_PID_INFO_INDEX_VIDEO_MEMORY_USAGE;
            info.pidInfoList[j].result = NV_ERR_GENERIC;
        }
        NvU32 requested = info.pidInfoListCount;
        st = QUERY(subdevice, NV2080_CTRL_CMD_GPU_GET_PID_INFO, info);
        for (NvU32 j = 0; j < requested; j++) {
            NV2080_CTRL_GPU_PID_INFO *row = &info.pidInfoList[j];
            NvU32 rs = st ? st : row->result;
            NV2080_CTRL_GPU_PID_INFO_VIDEO_MEMORY_USAGE_DATA *m = &row->data.vidMemUsage;
            [rows addObject:@{@"pid": @(pids.pidTbl[start + j]), @"vram": rs ? failure(rs) :
                @{@"private_bytes": @(m->memPrivate), @"shared_owned_bytes": @(m->memSharedOwned),
                  @"shared_duped_bytes": @(m->memSharedDuped)}}];
        }
    }
}

// Match cl00de.h's sequence read with bounded retries. Timestamp freshness is not inferred.
static BOOL readShared(const void *source, void *dest, size_t size)
{
    const volatile NvU64 *seq = source;
    for (int i = 0; i < 10; i++) {
        NvU64 before = *seq;
        atomic_thread_fence(memory_order_seq_cst);
        if (!RUSD_SEQ_DATA_VALID(before)) continue;
        memcpy(dest, source, size);
        atomic_thread_fence(memory_order_seq_cst);
        if (before == *seq) return YES;
    }
    return NO;
}

static BOOL seqPublished(const void *field)
{
    const volatile NvU64 *seq = field;
    return RUSD_SEQ_DATA_VALID(*seq);
}

static void applyRusdFailure(NSDictionary *err)
{
    output[@"rusd"] = err;
    for (NSString *key in @[@"fan_rpm_slots", @"power_draw_w", @"power_average_w", @"power_limit_w",
            @"power_limit_requested_w", @"gpu_utilization_percent", @"memory_utilization_percent",
            @"clock_graphics_mhz", @"clock_memory_mhz", @"clock_video_mhz", @"clock_sm_mhz"])
        if ([output[key] isKindOfClass:NSDictionary.class]) output[key] = err;
}

// CLOCK|PERF covers clocks and gpu/memory utilisation; POWER covers draw, average, and limits; FAN covers RPM slots.
enum { kRusdPollMask = NV00DE_RUSD_POLL_CLOCK | NV00DE_RUSD_POLL_PERF | NV00DE_RUSD_POLL_POWER | NV00DE_RUSD_POLL_FAN };

static void sharedInfo(void)
{
    NvHandle shared = 0x71000003;
    NV00DE_ALLOC_PARAMETERS ap = { .polledDataMask = 0 }; // Default: do not request firmware sampling.
    NvU32 st = allocObject(subdevice, &shared, RM_USER_SHARED_DATA, &ap, sizeof ap);
    if (st) { applyRusdFailure(failureCall(st, @"alloc_0xde")); return; }
    BOOL pollArmed = NO;
    if (wantPoll) {
        NV00DE_CTRL_REQUEST_DATA_POLL_PARAMS req = { .polledDataMask = kRusdPollMask };
        st = control(shared, NV00DE_CTRL_CMD_REQUEST_DATA_POLL, &req, sizeof req);
        if (st) output[@"rusd_poll"] = failureCall(st, @"request_data_poll");
        else { pollArmed = YES; output[@"rusd_poll"] = @{@"mask": @(kRusdPollMask), @"status": @"ok"}; }
    }
    io_connect_t mapConn = 0;
    int mapFd = -1;
    mach_vm_address_t address = 0;
    // RM checks offset+length against Memory.Length, which is sizeof(NV00DE_SHARED_DATA)
    // (3152 with these headers), not the page-rounded allocation. Rounding up to 4096
    // is NV_ERR_INVALID_LIMIT (0x2E). IOKit then maps the whole kernel descriptor.
    const NvU64 rmLength = sizeof(NV00DE_SHARED_DATA);
    mach_vm_size_t length = 0; // IOKit maps the kernel descriptor; 0 means the whole prepared range.
    nv_ioctl_nvos33_parameters_with_fd map = { .params = { .hClient = client,
        .hDevice = subdevice, .hMemory = shared, .length = rmLength,
        .flags = NVOS33_FLAGS_ACCESS_READ_ONLY, .status = NV_ERR_GENERIC } };
    BOOL rmMapped = NO;
    NSString *mapCall = @"map_0xde_open";
    st = openControl(&mapConn, &mapFd);
    if (!st) {
        map.fd = mapFd;
        mapCall = @"map_0xde";
        st = escape(connection, NV_ESC_RM_MAP_MEMORY, &map, sizeof map);
        if (!st) st = map.params.status;
        rmMapped = st == NV_OK;
    }
    if (!st) {
        checkpoint(@"map_rusd");
        errorDomain = @"iokit";
        mapCall = @"map_rusd_iokit";
        st = IOConnectMapMemory64(mapConn, 0, mach_task_self(), &address, &length, kIOMapAnywhere | kIOMapReadOnly);
    }
    if (!st && length < sizeof(NV00DE_SHARED_DATA)) {
        errorDomain = @"probe"; st = NV_ERR_INVALID_LIMIT; mapCall = @"map_rusd_length";
    }
    if (st) applyRusdFailure(failureCall(st, mapCall));
    else {
        const NV00DE_SHARED_DATA *s = (const void *)(uintptr_t)address;
        NSMutableDictionary *timestamps = [NSMutableDictionary dictionary];
        NSMutableDictionary *rusd = [@{@"polled_data_mask_requested": pollArmed ? @(kRusdPollMask) : @0,
            @"freshness": @"unverified", @"timestamps": timestamps} mutableCopy];
        int waitMs = 0;
        if (pollArmed) {
            checkpoint(@"rusd_poll_wait");
            struct timespec start, now;
            clock_gettime(CLOCK_MONOTONIC, &start);
            while (!seqPublished(&s->clkPublicDomainInfos) || !seqPublished(&s->perfDevUtil) ||
                   !seqPublished(&s->instPowerUsage) || !seqPublished(&s->avgPowerUsage) ||
                   !seqPublished(&s->powerLimitGpu) || !seqPublished(&s->fanCoolerStatus)) {
                clock_gettime(CLOCK_MONOTONIC, &now);
                double elapsed = (double)(now.tv_sec - start.tv_sec) + (double)(now.tv_nsec - start.tv_nsec) / 1e9;
                if (elapsed >= 2.0) break;
                usleep(50000);
            }
            clock_gettime(CLOCK_MONOTONIC, &now);
            waitMs = (int)((now.tv_sec - start.tv_sec) * 1000 + (now.tv_nsec - start.tv_nsec) / 1000000);
            BOOL ready = seqPublished(&s->clkPublicDomainInfos) && seqPublished(&s->perfDevUtil) &&
                seqPublished(&s->instPowerUsage) && seqPublished(&s->avgPowerUsage) &&
                seqPublished(&s->powerLimitGpu) && seqPublished(&s->fanCoolerStatus);
            rusd[@"poll_wait_ms"] = @(waitMs);
            rusd[@"poll_sequences"] = ready ? @"valid" : @"timeout";
            rusd[@"poll_valid"] = @{@"clock": @(seqPublished(&s->clkPublicDomainInfos)),
                @"util": @(seqPublished(&s->perfDevUtil)),
                @"power_draw": @(seqPublished(&s->instPowerUsage)),
                @"power_average": @(seqPublished(&s->avgPowerUsage)),
                @"power_limit": @(seqPublished(&s->powerLimitGpu)),
                @"fan": @(seqPublished(&s->fanCoolerStatus))};
        }
        output[@"rusd"] = rusd;
#define READ_SHARED(type, field, ...) do { type value; if (readShared(&s->field, &value, sizeof value)) { \
        timestamps[@#field] = @(value.lastModifiedTimestamp); __VA_ARGS__; } } while (0)
        READ_SHARED(RUSD_CLK_PUBLIC_DOMAIN_INFOS, clkPublicDomainInfos, {
            NSArray *keys = @[@"clock_graphics_mhz", @"clock_memory_mhz", @"clock_video_mhz", @"clock_sm_mhz"];
            for (NvU32 i = 0; i < RUSD_CLK_PUBLIC_DOMAIN_MAX_TYPE; i++)
                if (value.info[i].actualClkKHz != 0xffffffffu)
                    output[keys[i]] = @(value.info[i].actualClkKHz / 1000.0);
        });
        READ_SHARED(RUSD_PERF_DEVICE_UTILIZATION, perfDevUtil, {
            if (value.info.gpuPercentBusy <= 100) output[@"gpu_utilization_percent"] = @(value.info.gpuPercentBusy);
            if (value.info.memoryPercentBusy <= 100) output[@"memory_utilization_percent"] = @(value.info.memoryPercentBusy);
        });
        READ_SHARED(RUSD_INST_POWER_USAGE, instPowerUsage, { output[@"power_draw_w"] = @(value.info.instGpuPower / 1000.0); });
        READ_SHARED(RUSD_AVG_POWER_USAGE, avgPowerUsage, { output[@"power_average_w"] = @(value.info.averageGpuPower / 1000.0); });
        READ_SHARED(RUSD_POWER_LIMITS, powerLimitGpu, {
            output[@"power_limit_w"] = @(value.info.enforcedmW / 1000.0);
            output[@"power_limit_requested_w"] = @(value.info.requestedmW / 1000.0);
        });
        READ_SHARED(RUSD_FAN_COOLER_STATUS, fanCoolerStatus, {
            NSMutableArray *rpm = [NSMutableArray array];
            for (NvU32 i = 0; i < RUSD_FAN_COOLER_MAX_COOLERS; i++) [rpm addObject:@(value.info.rpmCurr[i])];
            output[@"fan_rpm_slots"] = rpm; // No validity mask/count in public struct; zero can mean absent or stopped.
        });
#undef READ_SHARED
    }
    if (address) {
        checkpoint(@"unmap_rusd");
        kern_return_t kr = IOConnectUnmapMemory64(mapConn, 0, mach_task_self(), address);
        if (kr) { errorDomain = @"iokit"; output[@"rusd_unmap"] = failureCall(kr, @"unmap_rusd_iokit"); }
    }
    if (rmMapped) {
        NVOS34_PARAMETERS unmap = { .hClient = client, .hDevice = subdevice, .hMemory = shared,
            .pLinearAddress = map.params.pLinearAddress, .status = NV_ERR_GENERIC };
        st = escape(connection, NV_ESC_RM_UNMAP_MEMORY, &unmap, sizeof unmap);
        if (!st) st = unmap.status;
        if (st) output[@"rusd_rm_unmap"] = failureCall(st, @"unmap_0xde");
    }
    if (mapConn) {
        checkpoint(@"close_rusd");
        kern_return_t kr = IOServiceClose(mapConn);
        if (kr) { errorDomain = @"iokit"; output[@"rusd_close"] = failureCall(kr, @"close_rusd"); }
    }
    if (mapFd >= 0 && close(mapFd)) { errorDomain = @"posix"; output[@"rusd_fd_close"] = failureCall((NvU32)errno, @"close_rusd_fd"); }
    // Drop the poll mask before process exit. Destructor recomputes the union and sends another GSP RPC.
    if (wantPoll) {
        NVOS00_PARAMETERS freeShared = { .hRoot = client, .hObjectOld = shared, .status = NV_ERR_GENERIC };
        st = escape(connection, NV_ESC_RM_FREE, &freeShared, sizeof freeShared);
        if (!st) st = freeShared.status;
        if (st) output[@"rusd_free"] = failureCall(st, @"free_0xde");
    }
}

static void grantInfo(void)
{
    NSArray *names = @[@"debug.nvrmfb_vram_mapped_bytes", @"debug.nvrmfb_vram_budget_bytes"];
    NSArray *keys = @[@"bar1_grant_mapped_bytes", @"bar1_grant_budget_bytes"];
    for (NSUInteger i = 0; i < names.count; i++) {
        int64_t value = 0;
        size_t size = sizeof value;
        checkpoint(names[i]);
        if (sysctlbyname([names[i] UTF8String], &value, &size, NULL, 0)) {
            errorDomain = @"posix"; output[keys[i]] = failure((NvU32)errno);
        } else output[keys[i]] = size == sizeof value && value >= 0 ? (id)@(value) : unavailable(@"invalid_sysctl_value");
    }
}

int main(int argc, char **argv)
{
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--poll")) wantPoll = 1;
        else {
            fputs("{\"schema_version\":1,\"probe\":{\"domain\":\"probe\",\"error\":\"unknown_argument\",\"call\":\"args\"}}\n", stdout);
            return 0;
        }
    }
    @autoreleasepool {
        output = [NSMutableDictionary dictionaryWithDictionary:@{@"schema_version": @1,
            @"timestamp_unix_s": @([NSDate date].timeIntervalSince1970)}];
        NSArray *keys = @[@"gpu_name", @"gpu_uuid", @"driver_version", @"gsp_firmware_version", @"vbios_version", @"sm_version_raw",
            @"temperature_core_c", @"temperature_memory_c", @"temperature_hotspot_c", @"thermal_sensors",
            @"fan_rpm_slots", @"fan_percent", @"clock_graphics_mhz", @"clock_memory_mhz", @"clock_video_mhz", @"clock_sm_mhz",
            @"clock_graphics_max_mhz", @"clock_memory_max_mhz", @"clock_video_max_mhz", @"clock_level_info_raw", @"clock_pmumon",
            @"power_draw_w", @"power_average_w", @"power_limit_w", @"power_limit_requested_w", @"performance_state",
            @"gpu_utilization_percent", @"memory_utilization_percent", @"vram_total_bytes", @"vram_heap_bytes",
            @"vram_used_bytes", @"vram_free_bytes", @"bar1_total_bytes", @"bar1_used_bytes", @"bar1_free_bytes",
            @"bar1_largest_free_bytes", @"pcie_generation", @"pcie_width", @"process_vram", @"nvrm_clients_by_pid", @"rusd", @"bar1_grant_mapped_bytes", @"bar1_grant_budget_bytes"];
        for (NSString *key in keys) output[key] = unavailable(@"not_attempted");
        for (NSString *key in @[@"fan_percent", @"temperature_hotspot_c", @"clock_graphics_max_mhz",
                @"clock_memory_max_mhz", @"clock_video_max_mhz", @"nvrm_clients_by_pid"])
            output[key] = unavailable(@"no_verified_public_abi");
        checkpoint(@"start");
        struct sigaction action = {0};
        action.sa_handler = timedOut;
        sigemptyset(&action.sa_mask);
        if (sigaction(SIGALRM, &action, NULL)) {
            errorDomain = @"posix"; output[@"setup"] = failure((NvU32)errno);
        } else {
            alarm(wantPoll ? 17 : 15);
            grantInfo();
            NvU32 st = openControl(&connection, &boundFd);
            if (!st) st = allocObject(0, &client, NV01_ROOT_CLIENT, NULL, 0);
            NV0000_CTRL_GPU_GET_ATTACHED_IDS_PARAMS ids = {0};
            if (!st) st = QUERY(client, NV0000_CTRL_CMD_GPU_GET_ATTACHED_IDS, ids);
            if (!st && ids.gpuIds[0] == 0xffffffffu) st = NV_ERR_OBJECT_NOT_FOUND;
            NV0000_CTRL_GPU_GET_ID_INFO_V2_PARAMS idInfo = { .gpuId = ids.gpuIds[0] };
            if (!st) st = QUERY(client, NV0000_CTRL_CMD_GPU_GET_ID_INFO_V2, idInfo);
            NV0080_ALLOC_PARAMETERS dp = { .deviceId = idInfo.deviceInstance, .hClientShare = client };
            NV2080_ALLOC_PARAMETERS sp = { .subDeviceId = idInfo.subDeviceInstance };
            if (!st) st = allocObject(client, &device, NV01_DEVICE_0, &dp, sizeof dp);
            if (!st) st = allocObject(device, &subdevice, NV20_SUBDEVICE_0, &sp, sizeof sp);
            if (st) {
                NSDictionary *why = failure(st);
                output[@"setup"] = why;
                for (NSString *key in keys) if ([output[key] isKindOfClass:NSDictionary.class] &&
                    [output[key][@"error"] isEqual:@"not_attempted"]) output[key] = why;
            } else {
                output[@"setup"] = @"ok";
                identity(); memoryInfo(); linkInfo(); thermalInfo(); perfInfo(); processInfo(); sharedInfo();
                for (NSString *key in keys) if ([output[key] isKindOfClass:NSDictionary.class] &&
                    [output[key][@"error"] isEqual:@"not_attempted"]) output[key] = unavailable(@"not_exposed_or_cache_invalid");
            }
            if (client) {
                NVOS00_PARAMETERS freeRoot = { .hRoot = client, .hObjectOld = client, .status = NV_ERR_GENERIC };
                st = escape(connection, NV_ESC_RM_FREE, &freeRoot, sizeof freeRoot);
                if (!st) st = freeRoot.status;
                if (st) output[@"rm_cleanup"] = failure(st);
            }
            if (connection) {
                checkpoint(@"close");
                kern_return_t kr = IOServiceClose(connection);
                if (kr) { errorDomain = @"iokit"; output[@"connection_close"] = failure(kr); }
            }
            if (boundFd >= 0 && close(boundFd)) { errorDomain = @"posix"; output[@"fd_close"] = failure((NvU32)errno); }
        }
        output[@"probe"] = @"complete";
        [output removeObjectForKey:@"stage"];
        NSData *data = [NSJSONSerialization dataWithJSONObject:output options:NSJSONWritingSortedKeys error:NULL];
        alarm(0);
        if (data) {
            NSMutableData *line = [data mutableCopy];
            [line appendBytes:"\n" length:1];
            const char *bytes = line.bytes;
            size_t off = 0;
            while (off < line.length) {
                ssize_t n = write(STDOUT_FILENO, bytes + off, line.length - off);
                if (n > 0) off += (size_t)n;
                else if (n < 0 && errno == EINTR) continue;
                else break;
            }
        } else { static const char failed[] = "{\"probe\":{\"error\":\"json_serialization\"}}\n"; (void)write(STDOUT_FILENO, failed, sizeof failed - 1); }
    }
    return 0;
}
