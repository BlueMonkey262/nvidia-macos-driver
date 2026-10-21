// Copyright (c) 2026 BlueMonkey
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CryptoKit
import Foundation

/// Runs the `nvmtlctl` CLI off the main thread.
actor NvmtlCtl {
    struct RunResult: Sendable {
        var exitCode: Int32
        var stdout: String
        var stderr: String

        var combinedMessage: String {
            let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if out.isEmpty { return err }
            if err.isEmpty { return out }
            return out + "\n" + err
        }
    }

    enum ToolError: Error, LocalizedError, Equatable {
        case toolMissing
        case rootToolMissing
        case timedOut(seconds: TimeInterval)
        case nonZeroExit(code: Int32, message: String)
        case invalidUTF8
        case cancelled

        var errorDescription: String? {
            switch self {
            case .toolMissing:
                return String(
                    localized: "Could not find nvmtlctl. Install it at /usr/local/bin/nvmtlctl, or confirm the app bundle includes the nvmtlctl resource."
                )
            case .rootToolMissing:
                return String(
                    localized: "This action needs administrator rights, and the app only runs the root-owned copy of nvmtlctl in /Library/Application Support/GPU Control/bin. That copy is missing or failed its check. Run sudo ./fork-install.sh from the driver package, then try again."
                )
            case .timedOut(let seconds):
                let wholeSeconds = Int(seconds)
                return String(
                    localized: "nvmtlctl did not finish within \(wholeSeconds) seconds. Try again, or run the same command in Terminal to see where it stalls."
                )
            case .nonZeroExit(let code, let message):
                if message.isEmpty {
                    return String(localized: "nvmtlctl exited with status \(code).")
                }
                return String(localized: "nvmtlctl exited with status \(code): \(message)")
            case .invalidUTF8:
                return String(localized: "nvmtlctl returned output that is not valid UTF-8.")
            case .cancelled:
                return String(localized: "The nvmtlctl command was cancelled.")
            }
        }
    }

    static let systemToolPath = "/usr/local/bin/nvmtlctl"
    static let bundledResourceName = "nvmtlctl"
    static let rootToolDirectory = "/Library/Application Support/GPU Control/bin"
    static let rootToolPath = rootToolDirectory + "/nvmtlctl"

    private let fileManager: FileManager
    private let defaultTimeout: TimeInterval

    init(fileManager: FileManager = .default, defaultTimeout: TimeInterval = 120) {
        self.fileManager = fileManager
        self.defaultTimeout = defaultTimeout
    }

    /// Prefer `/usr/local/bin/nvmtlctl`, then the copy inside the app bundle.
    func resolveToolPath() -> String? {
        if fileManager.isExecutableFile(atPath: Self.systemToolPath) {
            return Self.systemToolPath
        }
        if let bundled = Bundle.main.url(forResource: Self.bundledResourceName, withExtension: nil) {
            let path = bundled.path
            if fileManager.isExecutableFile(atPath: path) || fileManager.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// The only copy that may run as administrator: root-owned, not writable by anyone else, in a root-owned
    /// directory, and matching the sha256 that `fork-install.sh` recorded next to it. A copy in the app bundle
    /// or in /usr/local/bin can be replaced by a non-admin account, so it is never run with elevated rights.
    func verifiedRootToolPath() -> String? {
        func ownedByRoot(_ path: String, directory: Bool) -> Bool {
            guard let attrs = try? fileManager.attributesOfItem(atPath: path),
                  let type = attrs[.type] as? FileAttributeType,
                  type == (directory ? .typeDirectory : .typeRegular),
                  (attrs[.ownerAccountID] as? NSNumber)?.intValue == 0,
                  let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue,
                  mode & 0o022 == 0 else {
                return false
            }
            return true
        }
        let path = Self.rootToolPath
        guard ownedByRoot("/Library/Application Support/GPU Control", directory: true),
              ownedByRoot(Self.rootToolDirectory, directory: true),
              ownedByRoot(path, directory: false),
              ownedByRoot(path + ".sha256", directory: false),
              fileManager.isExecutableFile(atPath: path),
              let recorded = try? String(contentsOfFile: path + ".sha256", encoding: .utf8),
              let expected = recorded.split(separator: " ").first.map(String.init),
              let data = fileManager.contents(atPath: path) else {
            return nil
        }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return actual == expected ? path : nil
    }

    func status() async throws -> DriverStatus {
        let result = try await run(arguments: ["status", "--json"], asRoot: false)
        try throwIfFailed(result)
        return try JSONDecoding.decodeStatus(fromUTF8: result.stdout)
    }

    /// Read-only RM metrics via `nvmtlctl telemetry --json` (needs `gpu_telemetry` next to the CLI). No root.
    func telemetry(timeout: TimeInterval = 20) async throws -> GPUTelemetry {
        let result = try await run(arguments: ["telemetry", "--json"], asRoot: false, timeout: timeout)
        try throwIfFailed(result)
        return try JSONDecoding.decodeTelemetry(fromUTF8: result.stdout)
    }

    func confList() async throws -> [ConfEntry] {
        let result = try await run(arguments: ["conf", "list", "--json"], asRoot: false)
        try throwIfFailed(result)
        return try JSONDecoding.decodeConfList(fromUTF8: result.stdout)
    }

    func cachesStatus() async throws -> CachesStatus {
        let result = try await run(arguments: ["caches", "status", "--json"], asRoot: false)
        try throwIfFailed(result)
        return try JSONDecoding.decodeCachesStatus(fromUTF8: result.stdout)
    }

    func confSet(key: String, value: String) async throws -> String {
        let result = try await run(arguments: ["conf", "set", key, value], asRoot: true)
        try throwIfFailed(result)
        return result.combinedMessage
    }

    func confUnset(key: String) async throws -> String {
        let result = try await run(arguments: ["conf", "unset", key], asRoot: true)
        try throwIfFailed(result)
        return result.combinedMessage
    }

    func cachesClear() async throws -> String {
        let result = try await run(arguments: ["caches", "clear"], asRoot: true)
        try throwIfFailed(result)
        return result.combinedMessage
    }

    func restartWindowServer() async throws -> String {
        let result = try await run(arguments: ["restart-windowserver"], asRoot: true)
        try throwIfFailed(result)
        return result.combinedMessage
    }

    func collectLogs(into directory: String) async throws -> String {
        let result = try await run(arguments: ["logs", directory], asRoot: false, timeout: 300)
        try throwIfFailed(result)
        return result.combinedMessage
    }

    func run(
        arguments: [String],
        asRoot: Bool,
        timeout: TimeInterval? = nil
    ) async throws -> RunResult {
        try Task.checkCancellation()
        guard let toolPath = asRoot ? verifiedRootToolPath() : resolveToolPath() else {
            throw asRoot ? ToolError.rootToolMissing : ToolError.toolMissing
        }

        let timeoutSeconds = timeout ?? defaultTimeout
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        if asRoot {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            let script = ShellEscaping.adminShellAppleScript(executable: toolPath, arguments: arguments)
            process.arguments = ["-e", script]
        } else {
            process.executableURL = URL(fileURLWithPath: toolPath)
            process.arguments = arguments
        }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        return try await runProcess(process, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe, timeout: timeoutSeconds)
    }

    private func throwIfFailed(_ result: RunResult) throws {
        if result.exitCode == 0 { return }
        throw ToolError.nonZeroExit(code: result.exitCode, message: result.combinedMessage)
    }

    private func runProcess(
        _ process: Process,
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        timeout: TimeInterval
    ) async throws -> RunResult {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ResumeGate(continuation)
            let resumeOnce: @Sendable (Result<RunResult, Error>) -> Void = { gate.resume($0) }

            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                if process.isRunning {
                    process.terminate()
                }
                resumeOnce(.failure(ToolError.timedOut(seconds: timeout)))
            }
            timer.resume()

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try process.run()
                } catch {
                    timer.cancel()
                    resumeOnce(.failure(error))
                    return
                }

                let group = DispatchGroup()
                let capture = PipeCapture()

                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { group.leave() }
                    do {
                        capture.setStdout(try stdoutPipe.fileHandleForReading.readToEnd() ?? Data())
                    } catch {
                        capture.setReadError(error)
                    }
                }

                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { group.leave() }
                    do {
                        capture.setStderr(try stderrPipe.fileHandleForReading.readToEnd() ?? Data())
                    } catch {
                        capture.setReadError(error)
                    }
                }

                process.waitUntilExit()
                group.wait()
                timer.cancel()

                let captured = capture.snapshot()
                if let readError = captured.readError {
                    resumeOnce(.failure(readError))
                    return
                }

                guard let stdout = String(data: captured.stdout, encoding: .utf8),
                      let stderr = String(data: captured.stderr, encoding: .utf8)
                else {
                    resumeOnce(.failure(ToolError.invalidUTF8))
                    return
                }

                resumeOnce(
                    .success(
                        RunResult(
                            exitCode: process.terminationStatus,
                            stdout: stdout,
                            stderr: stderr
                        )
                    )
                )
            }
        }
    }
}

/// Resumes a continuation exactly once, whichever of the exit, timeout or launch-failure paths gets there first.
private nonisolated final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private let continuation: CheckedContinuation<NvmtlCtl.RunResult, Error>

    init(_ continuation: CheckedContinuation<NvmtlCtl.RunResult, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<NvmtlCtl.RunResult, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        continuation.resume(with: result)
    }
}

/// Collects what the two pipe readers produce on background queues; every access goes through the lock.
private nonisolated final class PipeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var readError: Error?

    func setStdout(_ data: Data) { lock.lock(); stdout = data; lock.unlock() }
    func setStderr(_ data: Data) { lock.lock(); stderr = data; lock.unlock() }
    func setReadError(_ error: Error) { lock.lock(); readError = error; lock.unlock() }

    func snapshot() -> (stdout: Data, stderr: Data, readError: Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (stdout, stderr, readError)
    }
}
