// Copyright (c) 2026 BlueMonkey
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Observation

/// Installs and observes the user-owned `gpucontrol-pointerhelper` LaunchAgent.
@MainActor
@Observable
final class PointerHelperStore {
    private(set) var status: PointerHelperStatus = .notInstalled
    private(set) var isBusy = false
    private(set) var lastErrorMessage: String?

    /// User preference mirrored by the Sunshine toggle.
    var keepPointerVisibleWhileTyping: Bool {
        didSet {
            UserDefaults.standard.set(keepPointerVisibleWhileTyping, forKey: Self.preferenceKey)
        }
    }

    private static let preferenceKey = "KeepPointerVisibleWhileTyping"
    private static let launchAgentLabel = "com.bluemonkey.gpucontrol.pointerhelper"
    private static let bundledResourceName = "gpucontrol-pointerhelper"
    private static let privacyAccessibilityURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!

    init() {
        self.keepPointerVisibleWhileTyping = UserDefaults.standard.object(forKey: Self.preferenceKey) as? Bool ?? false
    }

    var privacySettingsURL: URL { Self.privacyAccessibilityURL }

    func refresh() async {
        status = await Task.detached(priority: .utility) {
            PointerHelperStatusLogic.resolve(
                snapshot: PointerHelperStatusLogic.Snapshot.capture()
            )
        }.value
    }

    /// Refresh status; if the user left the feature on, put the LaunchAgent back when missing.
    func loadIfNeeded() async {
        await refresh()
        if keepPointerVisibleWhileTyping {
            switch status {
            case .notInstalled, .error:
                await setEnabled(true)
            case .installedAndRunning, .needsAccessibility:
                break
            }
        }
    }

    func setEnabled(_ enabled: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        lastErrorMessage = nil
        defer { isBusy = false }

        keepPointerVisibleWhileTyping = enabled
        do {
            if enabled {
                try await installAndStart()
            } else {
                try await stopAndUninstall()
            }
            await refresh()
        } catch {
            lastErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await refresh()
        }
    }

    private func installAndStart() async throws {
        guard let bundled = Bundle.main.url(forResource: Self.bundledResourceName, withExtension: nil) else {
            throw PointerHelperError.bundledHelperMissing
        }
        let bundledPath = bundled.path
        let label = Self.launchAgentLabel

        try await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let paths = PointerHelperPaths.current()
            try fm.createDirectory(at: paths.supportDirectory, withIntermediateDirectories: true)
            if fm.fileExists(atPath: paths.installedBinary.path) {
                try fm.removeItem(at: paths.installedBinary)
            }
            try fm.copyItem(at: URL(fileURLWithPath: bundledPath), to: paths.installedBinary)
            try fm.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: paths.installedBinary.path
            )

            try fm.createDirectory(
                at: paths.launchAgentPlist.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let plist = PointerHelperStatusLogic.launchAgentPlistXML(
                label: label,
                programPath: paths.installedBinary.path
            )
            try plist.write(to: paths.launchAgentPlist, atomically: true, encoding: .utf8)

            try PointerHelperLaunchctl.bootout(label: label, uid: paths.uid)
            try PointerHelperLaunchctl.bootstrap(
                label: label,
                plistPath: paths.launchAgentPlist.path,
                uid: paths.uid
            )
        }.value
    }

    private func stopAndUninstall() async throws {
        let label = Self.launchAgentLabel
        try await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let paths = PointerHelperPaths.current()
            try PointerHelperLaunchctl.bootout(label: label, uid: paths.uid)
            if fm.fileExists(atPath: paths.launchAgentPlist.path) {
                try fm.removeItem(at: paths.launchAgentPlist)
            }
            if fm.fileExists(atPath: paths.installedBinary.path) {
                try fm.removeItem(at: paths.installedBinary)
            }
            let stateURL = paths.supportDirectory.appendingPathComponent("pointerhelper.state")
            if fm.fileExists(atPath: stateURL.path) {
                try? fm.removeItem(at: stateURL)
            }
        }.value
    }
}

// MARK: - Status model

nonisolated enum PointerHelperStatus: Equatable, Sendable {
    case notInstalled
    case installedAndRunning
    case needsAccessibility
    case error(String)

    var label: String {
        switch self {
        case .notInstalled:
            return String(localized: "Not installed")
        case .installedAndRunning:
            return String(localized: "Running")
        case .needsAccessibility:
            return String(localized: "Needs Accessibility access")
        case .error(let message):
            return message
        }
    }

    var systemImage: String {
        switch self {
        case .notInstalled:
            return "circle"
        case .installedAndRunning:
            return "checkmark.circle.fill"
        case .needsAccessibility:
            return "exclamationmark.triangle"
        case .error:
            return "xmark.octagon"
        }
    }
}

nonisolated enum PointerHelperError: Error, LocalizedError, Sendable {
    case bundledHelperMissing
    case launchctlFailed(String)

    var errorDescription: String? {
        switch self {
        case .bundledHelperMissing:
            return String(
                localized: "Could not find gpucontrol-pointerhelper in the app bundle. Build it with app/scripts/build-pointer-helper.sh and place it next to nvmtlctl."
            )
        case .launchctlFailed(let message):
            return String(localized: "launchctl failed: \(message)")
        }
    }
}

// MARK: - Paths

nonisolated struct PointerHelperPaths: Sendable {
    var uid: uid_t
    var supportDirectory: URL
    var installedBinary: URL
    var launchAgentPlist: URL

    static func current() -> PointerHelperPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support/GPU Control", isDirectory: true)
        let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        return PointerHelperPaths(
            uid: getuid(),
            supportDirectory: support,
            installedBinary: support.appendingPathComponent("gpucontrol-pointerhelper"),
            launchAgentPlist: agents.appendingPathComponent("com.bluemonkey.gpucontrol.pointerhelper.plist")
        )
    }
}

// MARK: - Pure status resolution

nonisolated enum PointerHelperStatusLogic {
    struct Snapshot: Equatable, Sendable {
        var binaryInstalled: Bool
        var plistInstalled: Bool
        var launchdLoaded: Bool
        var stateFileValue: String?

        static func capture() -> Snapshot {
            let fm = FileManager.default
            let paths = PointerHelperPaths.current()
            let stateURL = paths.supportDirectory.appendingPathComponent("pointerhelper.state")
            let stateValue: String?
            if let data = try? String(contentsOf: stateURL, encoding: .utf8) {
                stateValue = parseState(data)
            } else {
                stateValue = nil
            }
            let loaded = (try? PointerHelperLaunchctl.isLoaded(
                label: "com.bluemonkey.gpucontrol.pointerhelper",
                uid: paths.uid
            )) ?? false
            return Snapshot(
                binaryInstalled: fm.isExecutableFile(atPath: paths.installedBinary.path),
                plistInstalled: fm.fileExists(atPath: paths.launchAgentPlist.path),
                launchdLoaded: loaded,
                stateFileValue: stateValue
            )
        }

        static func parseState(_ body: String) -> String? {
            for line in body.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("state=") {
                    return String(trimmed.dropFirst("state=".count))
                }
            }
            return nil
        }
    }

    static func resolve(snapshot: Snapshot) -> PointerHelperStatus {
        if snapshot.stateFileValue == "needs_accessibility" {
            return .needsAccessibility
        }
        if snapshot.launchdLoaded && snapshot.binaryInstalled {
            return .installedAndRunning
        }
        if snapshot.binaryInstalled || snapshot.plistInstalled {
            if !snapshot.launchdLoaded {
                return .error(String(localized: "Installed but not running"))
            }
            return .installedAndRunning
        }
        return .notInstalled
    }

    static func launchAgentPlistXML(label: String, programPath: String) -> String {
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
        	</array>
        	<key>RunAtLoad</key>
        	<true/>
        	<key>KeepAlive</key>
        	<true/>
        	<key>ProcessType</key>
        	<string>Background</string>
        </dict>
        </plist>
        """
    }
}

// MARK: - launchctl (user domain, never root)

nonisolated enum PointerHelperLaunchctl {
    static func bootstrap(label: String, plistPath: String, uid: uid_t) throws {
        _ = label
        let domain = "gui/\(uid)"
        let result = try run(arguments: ["bootstrap", domain, plistPath])
        if result.exitCode != 0 {
            if result.combined.contains("already bootstrapped")
                || result.combined.contains("service already loaded")
            {
                return
            }
            throw PointerHelperError.launchctlFailed(
                result.combined.isEmpty ? "exit \(result.exitCode)" : result.combined
            )
        }
    }

    static func bootout(label: String, uid: uid_t) throws {
        let domain = "gui/\(uid)"
        let result = try run(arguments: ["bootout", "\(domain)/\(label)"])
        if result.exitCode != 0 {
            // Soft-ok when the job was not loaded.
            return
        }
    }

    static func isLoaded(label: String, uid: uid_t) throws -> Bool {
        let domain = "gui/\(uid)"
        let result = try run(arguments: ["print", "\(domain)/\(label)"])
        return result.exitCode == 0
    }

    private struct RunResult {
        var exitCode: Int32
        var combined: String
    }

    private static func run(arguments: [String]) throws -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let combined = [stdout, stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return RunResult(exitCode: process.terminationStatus, combined: combined)
    }
}
