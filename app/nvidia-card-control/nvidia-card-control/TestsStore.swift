// Copyright (c) 2026 BlueMonkey
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Observation

/// Main-actor store for `nvmtlctl test` list, params and run results.
@MainActor
@Observable
final class TestsStore {
    private(set) var definitions: [TestDefinition] = []
    private(set) var paramValues: [String: [String: String]] = [:]
    private(set) var resultsByID: [String: TestRunResult] = [:]
    /// Ordered results for the pasteboard report (single runs append; run-all replaces).
    private(set) var reportResults: [TestRunResult] = []
    private(set) var runningTestIDs: Set<String> = []
    private(set) var isLoadingList = false
    private(set) var isRunningAll = false
    private(set) var hasLoadedList = false
    private(set) var lastErrorMessage: String?
    private(set) var lastNoticeMessage: String?

    private let ctl: NvmtlCtl
    private var runTasks: [String: Task<Void, Never>] = [:]
    private var runAllTask: Task<Void, Never>?
    private var listTask: Task<Void, Never>?

    init(ctl: NvmtlCtl = NvmtlCtl()) {
        self.ctl = ctl
    }

    var isBusy: Bool {
        isLoadingList || isRunningAll || !runningTestIDs.isEmpty
    }

    var groupedSections: [TestGroupSection] {
        TestHelpers.groupedSections(from: definitions)
    }

    var availableDefinitions: [TestDefinition] {
        definitions.filter(\.available)
    }

    func loadListIfNeeded() async {
        guard !hasLoadedList else { return }
        await refreshList()
    }

    func refreshList() async {
        listTask?.cancel()
        let task = Task { await performRefreshList() }
        listTask = task
        await task.value
    }

    func paramValue(testID: String, key: String) -> String {
        if let value = paramValues[testID]?[key] {
            return value
        }
        guard let definition = definitions.first(where: { $0.id == testID }),
              let param = definition.params.first(where: { $0.key == key })
        else {
            return ""
        }
        return param.defaultString
    }

    func setParamValue(testID: String, key: String, value: String) {
        var values = paramValues[testID] ?? [:]
        values[key] = value
        paramValues[testID] = values
    }

    func setIntParam(testID: String, spec: TestParamSpec, raw: Int) {
        let clamped = TestHelpers.clampIntParam(raw, spec: spec)
        setParamValue(testID: testID, key: spec.key, value: String(clamped))
    }

    func isRunning(_ testID: String) -> Bool {
        runningTestIDs.contains(testID)
    }

    func run(testID: String) {
        guard let definition = definitions.first(where: { $0.id == testID }) else { return }
        guard definition.available else { return }
        guard !isRunning(testID), !isRunningAll else { return }

        runTasks[testID]?.cancel()
        let task = Task { await performRun(definition: definition) }
        runTasks[testID] = task
    }

    func runAll() {
        guard !isRunningAll, runningTestIDs.isEmpty else { return }
        guard !availableDefinitions.isEmpty else {
            lastErrorMessage = String(localized: "No available tests to run.")
            return
        }
        runAllTask?.cancel()
        let task = Task { await performRunAll() }
        runAllTask = task
    }

    func cancelAllRuns() {
        for task in runTasks.values {
            task.cancel()
        }
        runTasks.removeAll()
        runAllTask?.cancel()
        runAllTask = nil
        runningTestIDs.removeAll()
        isRunningAll = false
    }

    func copyReport(macos: String, gpu: String, toolVersion: String) -> String {
        TestHelpers.plainTextReport(
            macos: macos,
            gpu: gpu,
            toolVersion: toolVersion,
            definitions: definitions,
            results: reportResults
        )
    }

    func noteReportCopied() {
        lastNoticeMessage = String(localized: "Report copied to the clipboard.")
    }

    func dismissError() {
        lastErrorMessage = nil
    }

    func dismissNotice() {
        lastNoticeMessage = nil
    }

    private func performRefreshList() async {
        guard !isLoadingList else { return }
        isLoadingList = true
        lastErrorMessage = nil
        defer {
            isLoadingList = false
            hasLoadedList = true
        }

        do {
            try Task.checkCancellation()
            let list = try await ctl.testList()
            try Task.checkCancellation()
            definitions = list
            syncParamDefaults(with: list)
        } catch is CancellationError {
            // Leave prior list in place.
        } catch {
            lastErrorMessage = presentableError(error)
        }
    }

    private func performRun(definition: TestDefinition) async {
        let testID = definition.id
        runningTestIDs.insert(testID)
        lastErrorMessage = nil
        defer {
            runningTestIDs.remove(testID)
            runTasks[testID] = nil
        }

        let params = paramValues[testID] ?? TestHelpers.defaultParamValues(for: definition)
        let timeout = TestHelpers.timeoutSeconds(estimatedSeconds: definition.estimatedSeconds)

        do {
            try Task.checkCancellation()
            let result = try await ctl.testRun(
                id: testID,
                params: params,
                asRoot: definition.needsRoot,
                timeout: timeout
            )
            try Task.checkCancellation()
            resultsByID[testID] = result
            upsertReportResult(result)
        } catch is CancellationError {
            lastNoticeMessage = String(localized: "Cancelled \(definition.title).")
        } catch {
            lastErrorMessage = presentableError(error)
        }
    }

    private func performRunAll() async {
        isRunningAll = true
        lastErrorMessage = nil
        defer {
            isRunningAll = false
            runAllTask = nil
        }

        let totalEstimate = availableDefinitions.reduce(0) { $0 + $1.estimatedSeconds }
        let timeout = TestHelpers.timeoutSeconds(estimatedSeconds: totalEstimate)
        let needsRoot = availableDefinitions.contains(where: \.needsRoot)

        do {
            try Task.checkCancellation()
            let results = try await ctl.testRunAll(asRoot: needsRoot, timeout: timeout)
            try Task.checkCancellation()
            for result in results {
                resultsByID[result.id] = result
            }
            reportResults = results
            lastNoticeMessage = String(localized: "Finished \(results.count) tests.")
        } catch is CancellationError {
            lastNoticeMessage = String(localized: "Cancelled run all.")
        } catch {
            lastErrorMessage = presentableError(error)
        }
    }

    private func syncParamDefaults(with list: [TestDefinition]) {
        var next = paramValues
        for definition in list {
            var values = next[definition.id] ?? [:]
            for param in definition.params {
                if values[param.key] == nil {
                    values[param.key] = param.defaultString
                }
            }
            // Drop keys that are no longer declared.
            let allowed = Set(definition.params.map(\.key))
            values = values.filter { allowed.contains($0.key) }
            next[definition.id] = values
        }
        paramValues = next
    }

    private func upsertReportResult(_ result: TestRunResult) {
        if let index = reportResults.firstIndex(where: { $0.id == result.id }) {
            reportResults[index] = result
        } else {
            reportResults.append(result)
        }
    }

    private func presentableError(_ error: Error) -> String {
        if let toolError = error as? NvmtlCtl.ToolError {
            return toolError.localizedDescription
        }
        return error.localizedDescription
    }
}

extension TestsStore {
    /// Preview store with sample definitions; does not invoke nvmtlctl.
    static var preview: TestsStore {
        let store = TestsStore()
        store.applyPreviewData()
        return store
    }

    fileprivate func applyPreviewData() {
        definitions = TestDefinition.previewSamples
        for definition in definitions {
            paramValues[definition.id] = TestHelpers.defaultParamValues(for: definition)
        }
        resultsByID["encode-h264"] = .previewSample
        reportResults = [.previewSample]
        hasLoadedList = true
    }
}
