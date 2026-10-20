// Copyright (c) 2026 BlueMonkey
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AppKit
import CoreGraphics
import Foundation
import Observation

/// Owns Sunshine service state, conf edits, display choice, and troubleshooting actions.
@MainActor
@Observable
final class SunshineStore {
    private(set) var isRunning = false
    private(set) var version: String?
    private(set) var isBusy = false
    private(set) var lastErrorMessage: String?
    private(set) var needsRestart = false
    private(set) var startAtLogin = false
    private(set) var userLocalLoginAgentPresent = false
    private(set) var displays: [SunshineDisplayInfo] = []
    private(set) var displayChoice: SunshineDisplayChoice = .mainDisplay()
    private(set) var mirrorActive = false
    private(set) var lastLogErrorLine: String?
    private(set) var lastLogErrorTimestamp: String?

    // Conf-backed fields (Encoding / Service extras)
    private(set) var encoder: String = SunshineOptionSpec.defaultEncoder
    private(set) var hevcMode: Int = SunshineOptionSpec.defaultHevcMode
    private(set) var av1Mode: Int = SunshineOptionSpec.defaultAv1Mode
    private(set) var fecPercentage: Int = SunshineOptionSpec.defaultFecPercentage
    private(set) var sunshineName: String = ""
    private(set) var minLogLevel: String = SunshineOptionSpec.defaultMinLogLevel
    private(set) var upnpEnabled: Bool = false
    private(set) var port: Int = SunshineOptionSpec.defaultPort

    private let configStore = SunshineConfigStore()
    private var pollTask: Task<Void, Never>?

    static let sunshineAppPath = "/Applications/Sunshine.app"
    static let webUIURL = URL(string: "https://localhost:47990")!
    static let ourLoginAgentLabel = "com.bluemonkey.gpucontrol.sunshine-login"
    static let userLocalLoginAgentLabel = "com.local.sunshine-login"
    static let bundledToolName = "gpucontrol-sunshine-tool"

    private static let mainDisplayPickerID = "main"

    var capturePickerSelection: String {
        if displayChoice.useMainDisplay {
            return Self.mainDisplayPickerID
        }
        if let name = displayChoice.matchName,
           let w = displayChoice.matchPixelWidth,
           let h = displayChoice.matchPixelHeight,
           let match = displays.first(where: { $0.name == name && $0.pixelWidth == w && $0.pixelHeight == h })
        {
            return String(match.id)
        }
        return Self.mainDisplayPickerID
    }

    var mainDisplayPickerID: String { Self.mainDisplayPickerID }

    func loadIfNeeded() async {
        await refresh()
        startPolling()
    }

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await self?.refreshRunningStateOnly()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        await refreshRunningStateOnly()
        version = Self.readSunshineVersion()
        userLocalLoginAgentPresent = Self.isLaunchAgentPlistPresent(label: Self.userLocalLoginAgentLabel)
        startAtLogin = Self.isOurLoginAgentEnabled()
        displayChoice = SunshineDisplayChoiceStore.load()
        mirrorActive = SunshineDisplayMirroring.isAnyMirrorActive()
        await refreshDisplays()
        reloadConfIntoFields()
        refreshLastLogError()
    }

    func refreshRunningStateOnly() async {
        isRunning = await Task.detached(priority: .utility) {
            Self.isSunshineRunning()
        }.value
    }

    // MARK: - Service

    func start() async {
        await runBusy {
            if let tool = try? Self.ensureToolInstalled() {
                _ = try Self.runProcess(tool, arguments: ["launch"])
            } else {
                _ = try Self.runProcess("/usr/bin/open", arguments: ["-a", "Sunshine"])
            }
            needsRestart = false
            try await Task.sleep(for: .milliseconds(500))
            await refreshRunningStateOnly()
        }
    }

    func stop() async {
        await runBusy {
            await Self.terminateSunshine()
            needsRestart = false
            await refreshRunningStateOnly()
        }
    }

    func restart() async {
        await runBusy {
            await Self.terminateSunshine()
            if let tool = try? Self.ensureToolInstalled() {
                _ = try Self.runProcess(tool, arguments: ["launch"])
            } else {
                _ = try Self.runProcess("/usr/bin/open", arguments: ["-a", "Sunshine"])
            }
            needsRestart = false
            try await Task.sleep(for: .milliseconds(500))
            await refreshRunningStateOnly()
        }
    }

    func setStartAtLogin(_ enabled: Bool) async {
        await runBusy {
            if enabled {
                try Self.installLoginAgent()
            } else {
                try Self.removeLoginAgent()
            }
            startAtLogin = Self.isOurLoginAgentEnabled()
        }
    }

    func openWebUI() {
        NSWorkspace.shared.open(Self.webUIURL)
    }

    // MARK: - Display

    func refreshDisplays() async {
        do {
            let list = try await Task.detached(priority: .utility) {
                try Self.loadDisplaysJSON()
            }.value
            displays = list
        } catch {
            // Keep prior list; surface softly.
            if displays.isEmpty {
                lastErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func selectMainDisplay() async {
        await runBusy {
            var choice = displayChoice
            choice.useMainDisplay = true
            choice.matchName = nil
            choice.matchPixelWidth = nil
            choice.matchPixelHeight = nil
            try SunshineDisplayChoiceStore.save(choice)
            displayChoice = choice
            try mutateConf { doc in
                doc.removeValue(forKey: "output_name")
            }
            markRestartNeeded()
        }
    }

    func selectDisplay(_ info: SunshineDisplayInfo) async {
        await runBusy {
            let choice = SunshineDisplayChoice.matched(
                name: info.name,
                pixelWidth: info.pixelWidth,
                pixelHeight: info.pixelHeight,
                mirror: displayChoice.mirrorEnabled
            )
            try SunshineDisplayChoiceStore.save(choice)
            displayChoice = choice
            try mutateConf { doc in
                doc.setValue(String(info.id), forKey: "output_name")
            }
            markRestartNeeded()
        }
    }

    func setMirrorEnabled(_ enabled: Bool) async {
        await runBusy {
            var choice = displayChoice
            choice.mirrorEnabled = enabled
            try SunshineDisplayChoiceStore.save(choice)
            displayChoice = choice

            let root: CGDirectDisplayID
            if choice.useMainDisplay {
                root = CGMainDisplayID()
            } else if let name = choice.matchName,
                      let w = choice.matchPixelWidth,
                      let h = choice.matchPixelHeight,
                      let match = displays.first(where: {
                          $0.name == name && $0.pixelWidth == w && $0.pixelHeight == h
                      })
            {
                root = CGDirectDisplayID(match.id)
            } else {
                root = CGMainDisplayID()
            }
            SunshineDisplayMirroring.setMirrored(enabled, rootDisplay: root)
            mirrorActive = SunshineDisplayMirroring.isAnyMirrorActive()
        }
    }

    // MARK: - Encoding / conf knobs

    func setEncoder(_ value: String) async {
        await runBusy {
            try mutateConf { doc in
                if value.isEmpty {
                    doc.removeValue(forKey: "encoder")
                } else {
                    doc.setValue(value, forKey: "encoder")
                }
            }
            encoder = value.isEmpty ? "" : value
            markRestartNeeded()
        }
    }

    func setHevcMode(_ value: Int) async {
        let clamped = SunshineOptionSpec.clampHevcMode(value)
        await runBusy {
            try mutateConf { doc in
                if clamped == SunshineOptionSpec.defaultHevcMode {
                    doc.removeValue(forKey: "hevc_mode")
                } else {
                    doc.setValue(String(clamped), forKey: "hevc_mode")
                }
            }
            hevcMode = clamped
            markRestartNeeded()
        }
    }

    func setAv1Mode(_ value: Int) async {
        let clamped = SunshineOptionSpec.clampAv1Mode(value)
        await runBusy {
            try mutateConf { doc in
                if clamped == SunshineOptionSpec.defaultAv1Mode {
                    doc.removeValue(forKey: "av1_mode")
                } else {
                    doc.setValue(String(clamped), forKey: "av1_mode")
                }
            }
            av1Mode = clamped
            markRestartNeeded()
        }
    }

    func setFecPercentage(_ value: Int) async {
        let clamped = SunshineOptionSpec.clampFecPercentage(value)
        await runBusy {
            try mutateConf { doc in
                if clamped == SunshineOptionSpec.defaultFecPercentage {
                    doc.removeValue(forKey: "fec_percentage")
                } else {
                    doc.setValue(String(clamped), forKey: "fec_percentage")
                }
            }
            fecPercentage = clamped
            markRestartNeeded()
        }
    }

    func setSunshineName(_ value: String) async {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        await runBusy {
            try mutateConf { doc in
                if trimmed.isEmpty {
                    doc.removeValue(forKey: "sunshine_name")
                } else {
                    doc.setValue(trimmed, forKey: "sunshine_name")
                }
            }
            sunshineName = trimmed
            markRestartNeeded()
        }
    }

    func setMinLogLevel(_ value: String) async {
        await runBusy {
            try mutateConf { doc in
                if value == SunshineOptionSpec.defaultMinLogLevel {
                    doc.removeValue(forKey: "min_log_level")
                } else {
                    doc.setValue(value, forKey: "min_log_level")
                }
            }
            minLogLevel = value
            markRestartNeeded()
        }
    }

    func setUpnpEnabled(_ enabled: Bool) async {
        await runBusy {
            try mutateConf { doc in
                if !enabled {
                    doc.removeValue(forKey: "upnp")
                } else {
                    doc.setValue(SunshineOptionSpec.enabledFlagString(true), forKey: "upnp")
                }
            }
            upnpEnabled = enabled
            markRestartNeeded()
        }
    }

    func setPort(_ value: Int) async {
        let clamped = SunshineOptionSpec.clampPort(value)
        await runBusy {
            try mutateConf { doc in
                if clamped == SunshineOptionSpec.defaultPort {
                    doc.removeValue(forKey: "port")
                } else {
                    doc.setValue(String(clamped), forKey: "port")
                }
            }
            port = clamped
            markRestartNeeded()
        }
    }

    func resetEncoder() async { await setEncoder(SunshineOptionSpec.defaultEncoder) }
    func resetHevcMode() async { await setHevcMode(SunshineOptionSpec.defaultHevcMode) }
    func resetAv1Mode() async { await setAv1Mode(SunshineOptionSpec.defaultAv1Mode) }
    func resetFecPercentage() async { await setFecPercentage(SunshineOptionSpec.defaultFecPercentage) }
    func resetSunshineName() async { await setSunshineName("") }
    func resetMinLogLevel() async { await setMinLogLevel(SunshineOptionSpec.defaultMinLogLevel) }
    func resetUpnp() async { await setUpnpEnabled(false) }
    func resetPort() async { await setPort(SunshineOptionSpec.defaultPort) }

    // MARK: - Troubleshooting

    func openLog() {
        let url = SunshineConfigPaths.logFile
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            lastErrorMessage = String(localized: "Sunshine log not found at ~/.config/sunshine/sunshine.log.")
        }
    }

    func revealSettingsFile() {
        let url = SunshineConfigPaths.configFile
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            let dir = SunshineConfigPaths.configDirectory
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            NSWorkspace.shared.open(dir)
        }
    }

    func resetSettings() async {
        await runBusy {
            try configStore.resetSettingsFile()
            reloadConfIntoFields()
            markRestartNeeded()
        }
    }

    func refreshLastLogError() {
        let result = Self.scanLastErrorLine(logURL: SunshineConfigPaths.logFile)
        lastLogErrorLine = result?.line
        lastLogErrorTimestamp = result?.timestamp
    }

    // MARK: - Internals

    private func markRestartNeeded() {
        if isRunning {
            needsRestart = true
        }
    }

    private func reloadConfIntoFields() {
        let doc = (try? configStore.load()) ?? SunshineConfigDocument()
        let enc = doc.value(forKey: "encoder")
        encoder = enc ?? ""
        hevcMode = SunshineOptionSpec.clampHevcMode(
            SunshineOptionSpec.parseInt(doc.value(forKey: "hevc_mode")) ?? SunshineOptionSpec.defaultHevcMode
        )
        av1Mode = SunshineOptionSpec.clampAv1Mode(
            SunshineOptionSpec.parseInt(doc.value(forKey: "av1_mode")) ?? SunshineOptionSpec.defaultAv1Mode
        )
        fecPercentage = SunshineOptionSpec.clampFecPercentage(
            SunshineOptionSpec.parseInt(doc.value(forKey: "fec_percentage")) ?? SunshineOptionSpec.defaultFecPercentage
        )
        sunshineName = doc.value(forKey: "sunshine_name") ?? ""
        minLogLevel = doc.value(forKey: "min_log_level") ?? SunshineOptionSpec.defaultMinLogLevel
        upnpEnabled = SunshineOptionSpec.isEnabledFlag(doc.value(forKey: "upnp"))
        port = SunshineOptionSpec.clampPort(
            SunshineOptionSpec.parseInt(doc.value(forKey: "port")) ?? SunshineOptionSpec.defaultPort
        )
    }

    private func mutateConf(_ body: (inout SunshineConfigDocument) throws -> Void) throws {
        var doc = try configStore.load()
        try body(&doc)
        try configStore.save(doc)
    }

    private func runBusy(_ work: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        lastErrorMessage = nil
        defer { isBusy = false }
        do {
            try await work()
        } catch {
            lastErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Process / LaunchAgent (nonisolated helpers)

    nonisolated private static func isSunshineRunning() -> Bool {
        // Prefer `ps` so this stays off the main actor (SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor).
        if let result = try? runProcess("/bin/ps", arguments: ["-axo", "comm="]) {
            let hit = result.stdout.split(whereSeparator: \.isNewline).contains { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return t.hasSuffix("/Sunshine") || t == "Sunshine"
            }
            if hit { return true }
        }
        return false
    }

    @MainActor
    private static func terminateSunshine() async {
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            if let url = app.bundleURL, url.path == sunshineAppPath { return true }
            return app.bundleIdentifier?.localizedCaseInsensitiveContains("sunshine") == true
        }
        for app in apps {
            app.terminate()
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let still = await Task.detached(priority: .utility) { isSunshineRunning() }.value
            if !still { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        for app in NSWorkspace.shared.runningApplications.filter({ app in
            if let url = app.bundleURL, url.path == sunshineAppPath { return true }
            return app.bundleIdentifier?.localizedCaseInsensitiveContains("sunshine") == true
        }) {
            app.forceTerminate()
        }
    }

    nonisolated private static func readSunshineVersion() -> String? {
        let plist = URL(fileURLWithPath: sunshineAppPath)
            .appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: plist) as? [String: Any] else { return nil }
        if let short = dict["CFBundleShortVersionString"] as? String, !short.isEmpty {
            return short
        }
        if let ver = dict["CFBundleVersion"] as? String, !ver.isEmpty {
            return ver
        }
        return nil
    }

    nonisolated private static func launchAgentsDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    nonisolated private static func isLaunchAgentPlistPresent(label: String) -> Bool {
        let url = launchAgentsDirectory().appendingPathComponent("\(label).plist")
        return FileManager.default.fileExists(atPath: url.path)
    }

    nonisolated private static func isOurLoginAgentEnabled() -> Bool {
        let uid = getuid()
        let label = ourLoginAgentLabel
        if !isLaunchAgentPlistPresent(label: label) { return false }
        let result = try? runProcess("/bin/launchctl", arguments: ["print", "gui/\(uid)/\(label)"])
        return result?.exitCode == 0
    }

    nonisolated private static func supportDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GPU Control", isDirectory: true)
    }

    nonisolated private static func installedToolURL() -> URL {
        supportDirectory().appendingPathComponent(bundledToolName)
    }

    nonisolated private static func resolveBundledTool() -> URL? {
        Bundle.main.url(forResource: bundledToolName, withExtension: nil)
    }

    nonisolated private static func resolveInstalledOrBundledTool() -> String? {
        let installed = installedToolURL()
        if FileManager.default.isExecutableFile(atPath: installed.path) {
            return installed.path
        }
        return resolveBundledTool()?.path
    }

    /// Copy the bundled tool into Application Support when missing (Start / login / displays).
    nonisolated private static func ensureToolInstalled() throws -> String {
        let fm = FileManager.default
        let installed = installedToolURL()
        if fm.isExecutableFile(atPath: installed.path) {
            return installed.path
        }
        guard let bundled = resolveBundledTool() else {
            throw SunshineStoreError.bundledToolMissing
        }
        try fm.createDirectory(at: supportDirectory(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: installed.path) {
            try fm.removeItem(at: installed)
        }
        try fm.copyItem(at: bundled, to: installed)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installed.path)
        return installed.path
    }

    nonisolated private static func installLoginAgent() throws {
        let fm = FileManager.default
        let installedPath = try ensureToolInstalled()
        let installed = URL(fileURLWithPath: installedPath)

        let agents = launchAgentsDirectory()
        try fm.createDirectory(at: agents, withIntermediateDirectories: true)
        let plistURL = agents.appendingPathComponent("\(ourLoginAgentLabel).plist")
        let xml = loginAgentPlistXML(label: ourLoginAgentLabel, programPath: installed.path)
        try xml.write(to: plistURL, atomically: true, encoding: .utf8)

        let uid = getuid()
        _ = try? runProcess("/bin/launchctl", arguments: ["bootout", "gui/\(uid)/\(ourLoginAgentLabel)"])
        let boot = try runProcess(
            "/bin/launchctl",
            arguments: ["bootstrap", "gui/\(uid)", plistURL.path]
        )
        if boot.exitCode != 0 {
            let msg = boot.combined
            if msg.contains("already bootstrapped") || msg.contains("service already loaded") {
                return
            }
            throw SunshineStoreError.launchctlFailed(msg.isEmpty ? "exit \(boot.exitCode)" : msg)
        }
    }

    nonisolated private static func removeLoginAgent() throws {
        let uid = getuid()
        _ = try? runProcess("/bin/launchctl", arguments: ["bootout", "gui/\(uid)/\(ourLoginAgentLabel)"])
        let fm = FileManager.default
        let plistURL = launchAgentsDirectory().appendingPathComponent("\(ourLoginAgentLabel).plist")
        if fm.fileExists(atPath: plistURL.path) {
            try fm.removeItem(at: plistURL)
        }
        // Leave the tool binary; Display / Start still use it.
    }

    nonisolated private static func loginAgentPlistXML(label: String, programPath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        	<key>Label</key>
        	<string>\(label)</string>
        	<key>ProgramArguments</key>
        	<array>
        		<string>\(programPath)</string>
        		<string>launch</string>
        	</array>
        	<key>RunAtLoad</key>
        	<true/>
        	<key>LimitLoadToSessionType</key>
        	<string>Aqua</string>
        	<key>ProcessType</key>
        	<string>Interactive</string>
        </dict>
        </plist>
        """
    }

    nonisolated private static func loadDisplaysJSON() throws -> [SunshineDisplayInfo] {
        let tool = try ensureToolInstalled()
        let result = try runProcess(tool, arguments: ["displays", "--json"])
        if result.exitCode != 0 {
            throw SunshineStoreError.toolFailed(result.combined)
        }
        let data = Data(result.stdout.utf8)
        return try JSONDecoder().decode([SunshineDisplayInfo].self, from: data)
    }

    nonisolated private static func scanLastErrorLine(logURL: URL) -> (timestamp: String, line: String)? {
        guard let data = try? Data(contentsOf: logURL),
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        for line in lines.reversed() {
            let lower = line.lowercased()
            if lower.contains("[error]") || lower.contains(": error:") || lower.contains(" error: ") {
                let stamp = extractTimestamp(from: line) ?? ""
                return (stamp, line)
            }
        }
        return nil
    }

    nonisolated private static func extractTimestamp(from line: String) -> String? {
        // Sunshine: [2026-10-18 19:29:17.260]: Error: ...
        if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
            let inner = String(line[line.index(after: line.startIndex)..<close])
            if inner.contains("-") { return inner }
        }
        return nil
    }

    nonisolated private struct ProcessResult {
        var exitCode: Int32
        var stdout: String
        var stderr: String
        var combined: String {
            let parts = [stdout, stderr]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return parts.joined(separator: "\n")
        }
    }

    @discardableResult
    nonisolated private static func runProcess(_ executable: String, arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}

nonisolated enum SunshineStoreError: Error, LocalizedError, Sendable {
    case bundledToolMissing
    case launchctlFailed(String)
    case toolFailed(String)

    var errorDescription: String? {
        switch self {
        case .bundledToolMissing:
            return String(
                localized: "Could not find gpucontrol-sunshine-tool. Build it with app/scripts/build-sunshine-tool.sh and place it next to nvmtlctl."
            )
        case .launchctlFailed(let message):
            return String(localized: "launchctl failed: \(message)")
        case .toolFailed(let message):
            return String(localized: "gpucontrol-sunshine-tool failed: \(message)")
        }
    }
}
