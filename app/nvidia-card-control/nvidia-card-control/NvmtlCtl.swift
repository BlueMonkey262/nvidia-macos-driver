// Copyright (c) 2026 BlueMonkey
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

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

    func status() async throws -> DriverStatus {
        let result = try await run(arguments: ["status", "--json"], asRoot: false)
        try throwIfFailed(result)
        return try JSONDecoding.decodeStatus(fromUTF8: result.stdout)
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

    func testList() async throws -> [TestDefinition] {
        let result = try await run(arguments: TestHelpers.listArguments(), asRoot: false)
        try throwIfFailed(result)
        return try JSONDecoding.decodeTestList(fromUTF8: result.stdout)
    }

    /// Runs one test. Exit code 0 still returns a decoded result when the test itself failed.
    func testRun(
        id: String,
        params: [String: String],
        asRoot: Bool,
        timeout: TimeInterval
    ) async throws -> TestRunResult {
        let arguments = TestHelpers.runArguments(testID: id, params: params)
        let result = try await run(arguments: arguments, asRoot: asRoot, timeout: timeout)
        try throwIfFailed(result)
        return try JSONDecoding.decodeTestRunResult(fromUTF8: result.stdout)
    }

    /// Runs every available test. Exit code 0 still returns per-test fail/skip/error rows.
    func testRunAll(asRoot: Bool, timeout: TimeInterval) async throws -> [TestRunResult] {
        let result = try await run(
            arguments: TestHelpers.runAllArguments(),
            asRoot: asRoot,
            timeout: timeout
        )
        try throwIfFailed(result)
        return try JSONDecoding.decodeTestRunResults(fromUTF8: result.stdout)
    }

    func run(
        arguments: [String],
        asRoot: Bool,
        timeout: TimeInterval? = nil
    ) async throws -> RunResult {
        try Task.checkCancellation()
        guard let toolPath = resolveToolPath() else {
            throw ToolError.toolMissing
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
