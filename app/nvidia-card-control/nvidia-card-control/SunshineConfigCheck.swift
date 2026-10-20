// Copyright (c) 2026 BlueMonkey
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// Pure parser/writer self-check (no XCTest). Mirror of `tests/sunshine_config_selfcheck.py`.
nonisolated enum SunshineConfigCheck {
    static func failures() -> [String] {
        var failures: [String] = []

        do {
            let text = """
            # header comment
            min_log_level = info

            encoder = videotoolbox
            unknown_key = keepme
            """
            let doc = SunshineConfigDocument.parse(text)
            expect(doc.value(forKey: "min_log_level") == "info", "parse min_log_level", into: &failures)
            expect(doc.value(forKey: "encoder") == "videotoolbox", "parse encoder", into: &failures)
            expect(doc.value(forKey: "unknown_key") == "keepme", "parse unknown_key", into: &failures)
            expect(doc.value(forKey: "missing") == nil, "missing key is nil", into: &failures)

            let roundTrip = SunshineConfigDocument.parse(doc.serialize())
            expect(
                roundTrip.serialize() == doc.serialize(),
                "round-trip serialize stable",
                into: &failures
            )
            expect(
                doc.serialize().hasSuffix("\n"),
                "serialize ends with newline",
                into: &failures
            )
            expect(
                doc.serialize().contains("# header comment"),
                "preserves comment",
                into: &failures
            )
        }

        do {
            var doc = SunshineConfigDocument.parse("""
            # keep
            encoder = software
            min_log_level = debug
            """)
            doc.setValue("videotoolbox", forKey: "encoder")
            expect(doc.value(forKey: "encoder") == "videotoolbox", "setValue updates", into: &failures)
            expect(doc.serialize().contains("# keep"), "setValue keeps comment", into: &failures)
            expect(doc.serialize().contains("min_log_level = debug"), "setValue keeps other keys", into: &failures)

            doc.removeValue(forKey: "encoder")
            expect(doc.value(forKey: "encoder") == nil, "removeValue drops key", into: &failures)
            expect(doc.serialize().contains("min_log_level = debug"), "remove keeps others", into: &failures)
            expect(!doc.serialize().contains("encoder"), "remove drops encoder text", into: &failures)
        }

        do {
            var doc = SunshineConfigDocument.parse("a = 1\nencoder = x\na = 2\n")
            doc.setValue("y", forKey: "a")
            let serialized = doc.serialize()
            let count = serialized.components(separatedBy: "a = ").count - 1
            expect(count == 1, "setValue collapses duplicate keys", into: &failures)
            expect(doc.value(forKey: "a") == "y", "setValue uses new value", into: &failures)
            expect(doc.value(forKey: "encoder") == "x", "duplicates collapse keeps others", into: &failures)
        }

        do {
            var doc = SunshineConfigDocument()
            doc.setValue("info", forKey: "min_log_level")
            expect(doc.serialize() == "min_log_level = info\n", "insert into empty", into: &failures)
        }

        do {
            let doc = SunshineConfigDocument.parse("bare=value\nspaced = v\n")
            expect(doc.value(forKey: "bare") == "value", "parse bare =", into: &failures)
            expect(doc.value(forKey: "spaced") == "v", "parse spaced =", into: &failures)
        }

        do {
            let doc = SunshineConfigDocument.parse("key = value with = signs\n")
            expect(doc.value(forKey: "key") == "value with = signs", "value may contain =", into: &failures)
        }

        do {
            let fec = SunshineOptionSpec.clampFecPercentage(0)
            expect(fec == 1, "fec clamp low", into: &failures)
            expect(SunshineOptionSpec.clampFecPercentage(20) == 20, "fec pass-through", into: &failures)
            expect(SunshineOptionSpec.clampFecPercentage(300) == 255, "fec clamp high", into: &failures)
            expect(SunshineOptionSpec.clampPort(80) == 1024, "port clamp low", into: &failures)
            expect(SunshineOptionSpec.clampPort(47989) == 47989, "port pass-through", into: &failures)
            expect(SunshineOptionSpec.clampPort(70000) == 65535, "port clamp high", into: &failures)
        }

        return failures
    }

    private static func expect(_ condition: Bool, _ message: String, into failures: inout [String]) {
        if !condition { failures.append(message) }
    }
}
