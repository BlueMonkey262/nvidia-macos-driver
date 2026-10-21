// Copyright (c) 2026 BlueMonkey
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Observation

/// Main-actor store for driver status and settings.
@MainActor
@Observable
final class DriverStore {
    private(set) var status: DriverStatus?
    /// Last good `nvmtlctl telemetry` sample; tiles show dashes until the first success.
    private(set) var telemetry: GPUTelemetry = .unavailable
    /// When the last good telemetry sample arrived; used for the 5 s stale mark.
    private(set) var telemetrySampleDate: Date?
    private(set) var isTelemetryStale = false
    /// Why the last telemetry request failed; nil after a good sample. Shown on the Status page so a failure is not silent.
    private(set) var telemetryErrorMessage: String?
    private(set) var confEntries: [ConfEntry] = []
    private(set) var cachesStatus: CachesStatus?
    private(set) var toolPath: String?
    private(set) var isRefreshing = false
    private(set) var busyAction: BusyAction?
    private(set) var lastErrorMessage: String?
    private(set) var lastNoticeMessage: String?
    private(set) var hasCompletedInitialLoad = false

    enum BusyAction: Equatable {
        case refresh
        case setConf(String)
        case unsetConf(String)
        case clearCaches
        case restartDesktop
        case collectLogs
    }

    private let ctl: NvmtlCtl
    private var telemetryPollTask: Task<Void, Never>?
    private var telemetryRequestInFlight = false

    private static let telemetryStaleAfter: TimeInterval = 5
    private static let telemetryPollInterval: Duration = .seconds(1)

    init(ctl: NvmtlCtl = NvmtlCtl()) {
        self.ctl = ctl
    }

    var isBusy: Bool { busyAction != nil || isRefreshing }

    var toolIsMissing: Bool {
        hasCompletedInitialLoad && toolPath == nil && status == nil
    }

    func entry(for key: String) -> ConfEntry? {
        confEntries.first { $0.key == key }
    }

    func loadIfNeeded() async {
        guard !hasCompletedInitialLoad else { return }
        await refresh()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        busyAction = .refresh
        lastErrorMessage = nil
        defer {
            isRefreshing = false
            if busyAction == .refresh {
                busyAction = nil
            }
            hasCompletedInitialLoad = true
        }

        toolPath = await ctl.resolveToolPath()
        guard toolPath != nil else {
            status = nil
            confEntries = []
            cachesStatus = nil
            lastErrorMessage = NvmtlCtl.ToolError.toolMissing.localizedDescription
            return
        }

        do {
            async let statusTask = ctl.status()
            async let confTask = ctl.confList()
            async let cachesTask = ctl.cachesStatus()
            status = try await statusTask
            confEntries = try await confTask
            cachesStatus = try await cachesTask
            lastNoticeMessage = nil
        } catch is CancellationError {
            lastErrorMessage = NvmtlCtl.ToolError.cancelled.localizedDescription
        } catch {
            lastErrorMessage = presentableError(error)
        }
    }

    func setConf(key: String, value: String) async {
        guard ConfKey.isValidConfValue(value) else {
            lastErrorMessage = String(
                localized: "'\(value)' is not a valid setting value. Use letters, digits, underscore, period or hyphen only."
            )
            return
        }
        await performWrite(action: .setConf(key)) {
            _ = try await ctl.confSet(key: key, value: value)
            lastNoticeMessage = String(
                localized: "Saved \(key). App settings apply the next time an app starts; desktop settings need the desktop restarted."
            )
        }
    }

    func unsetConf(key: String) async {
        await performWrite(action: .unsetConf(key)) {
            _ = try await ctl.confUnset(key: key)
            lastNoticeMessage = String(localized: "Reset \(key) to the driver default.")
        }
    }

    func setFlag(key: String, enabled: Bool) async {
        await setConf(key: key, value: enabled ? "1" : "0")
    }

    func setPoolKeep(_ value: Int) async {
        let clamped = ConfKey.clampPoolKeep(value)
        await setConf(key: ConfKey.poolKeep, value: String(clamped))
    }

    func clearCaches() async {
        await performWrite(action: .clearCaches) {
            let message = try await ctl.cachesClear()
            lastNoticeMessage = message.isEmpty
                ? String(localized: "Icon caches cleared. Icons rebuild at the next login or restart.")
                : message
        }
    }

    func restartDesktop() async {
        await performWrite(action: .restartDesktop) {
            let message = try await ctl.restartWindowServer()
            lastNoticeMessage = message.isEmpty
                ? String(localized: "Restarting the desktop. Your session will end and come back.")
                : message
        }
    }

    func collectLogs(into directoryURL: URL) async -> URL? {
        var collectedURL: URL?
        await performWrite(action: .collectLogs) {
            let path = directoryURL.path
            let message = try await ctl.collectLogs(into: path)
            collectedURL = directoryURL
            lastNoticeMessage = message.isEmpty
                ? String(localized: "Logs collected in \(path).")
                : message
        }
        return collectedURL
    }

    func dismissError() {
        lastErrorMessage = nil
    }

    func dismissNotice() {
        lastNoticeMessage = nil
    }

    /// 1 Hz telemetry while the Status page is visible. One request in flight; missed ticks are skipped.
    func startTelemetryPolling() {
        stopTelemetryPolling()
        telemetryPollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.pollTelemetryTick()
                try? await Task.sleep(for: Self.telemetryPollInterval)
            }
        }
    }

    func stopTelemetryPolling() {
        telemetryPollTask?.cancel()
        telemetryPollTask = nil
        telemetryRequestInFlight = false
        refreshTelemetryStaleFlag()
    }

    private func pollTelemetryTick() async {
        refreshTelemetryStaleFlag()
        guard !telemetryRequestInFlight else { return }
        telemetryRequestInFlight = true
        defer { telemetryRequestInFlight = false }

        do {
            let sample = try await ctl.telemetry()
            telemetry = sample
            telemetrySampleDate = Date()
            isTelemetryStale = false
            telemetryErrorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            // Keep the last good sample; surface age via isTelemetryStale and the reason via telemetryErrorMessage.
            telemetryErrorMessage = presentableError(error)
            refreshTelemetryStaleFlag()
        }
    }

    private func refreshTelemetryStaleFlag() {
        guard let telemetrySampleDate else {
            isTelemetryStale = false
            return
        }
        isTelemetryStale = Date().timeIntervalSince(telemetrySampleDate) > Self.telemetryStaleAfter
    }

    private func performWrite(action: BusyAction, work: () async throws -> Void) async {
        guard busyAction == nil else { return }
        busyAction = action
        lastErrorMessage = nil
        defer { busyAction = nil }
        do {
            try await work()
            toolPath = await ctl.resolveToolPath()
            // Refresh read models after a successful write (restart may not return).
            if action != .restartDesktop {
                await refreshAfterWrite()
            }
        } catch is CancellationError {
            lastErrorMessage = NvmtlCtl.ToolError.cancelled.localizedDescription
        } catch {
            lastErrorMessage = presentableError(error)
        }
    }

    private func refreshAfterWrite() async {
        do {
            async let statusTask = ctl.status()
            async let confTask = ctl.confList()
            async let cachesTask = ctl.cachesStatus()
            status = try await statusTask
            confEntries = try await confTask
            cachesStatus = try await cachesTask
        } catch {
            // Keep the write notice; surface refresh failure separately.
            lastErrorMessage = presentableError(error)
        }
    }

    private func presentableError(_ error: Error) -> String {
        if let toolError = error as? NvmtlCtl.ToolError {
            return toolError.localizedDescription
        }
        return error.localizedDescription
    }
}

extension DriverStore {
    /// Preview store with sample data; does not invoke nvmtlctl.
    static var preview: DriverStore {
        let store = DriverStore()
        store.applyPreviewData()
        return store
    }

    fileprivate func applyPreviewData() {
        status = .previewSample
        telemetry = .previewSample
        telemetrySampleDate = Date()
        isTelemetryStale = false
        confEntries = ConfEntry.previewSamples
        cachesStatus = .previewSample
        toolPath = NvmtlCtl.systemToolPath
        hasCompletedInitialLoad = true
    }
}
