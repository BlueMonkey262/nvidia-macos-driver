// Copyright (c) 2026 BlueMonkey
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// One physical line in `sunshine.conf`. Comments and blanks keep their raw text; keyed lines
/// split on the first ` = ` (or `=`) so values may contain `=`.
nonisolated enum SunshineConfLine: Equatable, Sendable {
    case blank(String)
    case comment(String)
    case keyValue(key: String, value: String, raw: String)
    case other(String)

    var raw: String {
        switch self {
        case .blank(let s), .comment(let s), .other(let s):
            return s
        case .keyValue(_, _, let raw):
            return raw
        }
    }
}

/// In-memory `sunshine.conf` that preserves comments, unknown keys, order, and a trailing newline.
nonisolated struct SunshineConfigDocument: Equatable, Sendable {
    var lines: [SunshineConfLine]

    init(lines: [SunshineConfLine] = []) {
        self.lines = lines
    }

    static func parse(_ text: String) -> SunshineConfigDocument {
        var lines: [SunshineConfLine] = []
        // Split retaining whether the file ended with a newline by walking UTF-8 newlines.
        let pieces = splitKeepingNewlines(text)
        for piece in pieces {
            lines.append(classify(piece))
        }
        return SunshineConfigDocument(lines: lines)
    }

    /// Serialize. Always ends with a single trailing newline when non-empty (or when empty: one newline).
    func serialize() -> String {
        if lines.isEmpty {
            return "\n"
        }
        var body = lines.map(\.raw).joined(separator: "\n")
        if !body.hasSuffix("\n") {
            body.append("\n")
        }
        return body
    }

    func value(forKey key: String) -> String? {
        for line in lines {
            if case .keyValue(let k, let v, _) = line, k == key {
                return v
            }
        }
        return nil
    }

    /// Set or insert `key = value`. Preserves the first occurrence's position; removes duplicates.
    mutating func setValue(_ value: String, forKey key: String) {
        let rendered = "\(key) = \(value)"
        var found = false
        var result: [SunshineConfLine] = []
        for line in lines {
            if case .keyValue(let k, _, _) = line, k == key {
                if !found {
                    result.append(.keyValue(key: key, value: value, raw: rendered))
                    found = true
                }
                // Drop later duplicates.
            } else {
                result.append(line)
            }
        }
        if !found {
            // Avoid trailing blank-only growth: append before a final blank if present.
            if let last = result.last, case .blank = last {
                result.insert(.keyValue(key: key, value: value, raw: rendered), at: result.count - 1)
            } else {
                result.append(.keyValue(key: key, value: value, raw: rendered))
            }
        }
        lines = result
    }

    /// Remove every keyed line for `key`. Comments and other keys stay put.
    mutating func removeValue(forKey key: String) {
        lines.removeAll { line in
            if case .keyValue(let k, _, _) = line { return k == key }
            return false
        }
    }

    // MARK: - Parsing helpers

    private static func splitKeepingNewlines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var body = text
        if body.hasSuffix("\r\n") {
            body = String(body.dropLast(2))
        } else if body.hasSuffix("\n") {
            body = String(body.dropLast())
        }
        // A file that was only a newline becomes one blank line.
        if body.isEmpty {
            return [""]
        }
        return body.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            var s = String(line)
            if s.hasSuffix("\r") {
                s = String(s.dropLast())
            }
            return s
        }
    }

    private static func classify(_ line: String) -> SunshineConfLine {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return .blank(line)
        }
        if trimmed.hasPrefix("#") || trimmed.hasPrefix(";") {
            return .comment(line)
        }
        // Prefer " = " (Sunshine style), then bare "=".
        if let parsed = parseKeyValue(trimmed) {
            return .keyValue(key: parsed.key, value: parsed.value, raw: line)
        }
        return .other(line)
    }

    private static func parseKeyValue(_ trimmed: String) -> (key: String, value: String)? {
        if let range = trimmed.range(of: " = ") {
            let key = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return nil }
            return (key, value)
        }
        if let idx = trimmed.firstIndex(of: "=") {
            let key = String(trimmed[..<idx]).trimmingCharacters(in: .whitespaces)
            let after = trimmed.index(after: idx)
            let value = String(trimmed[after...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return nil }
            return (key, value)
        }
        return nil
    }
}

// MARK: - File IO (atomic write, session backup)

nonisolated enum SunshineConfigPaths {
    static var configDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/sunshine", isDirectory: true)
    }

    static var configFile: URL {
        configDirectory.appendingPathComponent("sunshine.conf")
    }

    static var logFile: URL {
        configDirectory.appendingPathComponent("sunshine.log")
    }

    /// Never read credentials / sunshine_state.json — listed only so callers can avoid them.
    static var credentialsFileName: String { "credentials" }
    static var stateFileName: String { "sunshine_state.json" }
}

/// Writes `sunshine.conf` atomically. Backs up once per process session before the first write,
/// keeping at most `maxBackups` timestamped `sunshine.conf.bak-*` files.
nonisolated final class SunshineConfigStore: @unchecked Sendable {
    static let maxBackups = 5

    private let fileManager: FileManager
    private let configURL: URL
    private let lock = NSLock()
    private var didBackupThisSession = false

    init(
        fileManager: FileManager = .default,
        configURL: URL = SunshineConfigPaths.configFile
    ) {
        self.fileManager = fileManager
        self.configURL = configURL
    }

    func load() throws -> SunshineConfigDocument {
        if !fileManager.fileExists(atPath: configURL.path) {
            return SunshineConfigDocument()
        }
        let data = try Data(contentsOf: configURL)
        guard let text = String(data: data, encoding: .utf8) else {
            throw SunshineConfigError.invalidUTF8
        }
        return SunshineConfigDocument.parse(text)
    }

    func save(_ document: SunshineConfigDocument) throws {
        try fileManager.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        lock.lock()
        let needsBackup = !didBackupThisSession
        if needsBackup {
            didBackupThisSession = true
        }
        lock.unlock()

        if needsBackup, fileManager.fileExists(atPath: configURL.path) {
            try backupExistingConfig()
        }

        let text = document.serialize()
        guard let data = text.data(using: .utf8) else {
            throw SunshineConfigError.invalidUTF8
        }
        try atomicWrite(data: data, to: configURL)
    }

    /// Back up then delete only `sunshine.conf`. Never touches credentials or state.
    func resetSettingsFile() throws {
        if fileManager.fileExists(atPath: configURL.path) {
            try backupExistingConfig()
            try fileManager.removeItem(at: configURL)
        }
        lock.lock()
        didBackupThisSession = true
        lock.unlock()
    }

    private func backupExistingConfig() throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = formatter.string(from: Date())
        let backupName = "sunshine.conf.bak-\(stamp)"
        let backupURL = configURL.deletingLastPathComponent().appendingPathComponent(backupName)
        if fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.removeItem(at: backupURL)
        }
        try fileManager.copyItem(at: configURL, to: backupURL)
        try trimBackups()
    }

    private func trimBackups() throws {
        let dir = configURL.deletingLastPathComponent()
        let contents = try fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let backups = contents
            .filter { $0.lastPathComponent.hasPrefix("sunshine.conf.bak-") }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
        for extra in backups.dropFirst(Self.maxBackups) {
            try? fileManager.removeItem(at: extra)
        }
    }

    private func atomicWrite(data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let tempName = ".\(url.lastPathComponent).tmp-\(UUID().uuidString)"
        let tempURL = dir.appendingPathComponent(tempName)

        let previousMode: NSNumber?
        if fileManager.fileExists(atPath: url.path) {
            previousMode = try fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        } else {
            previousMode = nil
        }

        do {
            try data.write(to: tempURL, options: .withoutOverwriting)
            let handle = try FileHandle(forWritingTo: tempURL)
            try handle.synchronize()
            try handle.close()

            if let previousMode {
                try fileManager.setAttributes(
                    [.posixPermissions: previousMode],
                    ofItemAtPath: tempURL.path
                )
            } else {
                try fileManager.setAttributes(
                    [.posixPermissions: 0o644],
                    ofItemAtPath: tempURL.path
                )
            }

            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: url)
            }
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw error
        }
    }
}

nonisolated enum SunshineConfigError: Error, LocalizedError, Sendable {
    case invalidUTF8

    var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return String(localized: "Sunshine settings file is not valid UTF-8.")
        }
    }
}
