// Copyright (c) 2026 BlueMonkey
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// Pure helpers for building a safe `osascript` `do shell script` line.
/// Kept free of Process/UI so they can be unit-tested later.
nonisolated enum ShellEscaping {
    /// Escape a value for inclusion inside a double-quoted AppleScript string.
    static func appleScriptString(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\":
                result += "\\\\"
            case "\"":
                result += "\\\""
            case "\n":
                result += "\\n"
            case "\r":
                result += "\\r"
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// Wrap a value in POSIX single quotes (`'` → `'\''`).
    static func posixSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Build `do shell script "…" with administrator privileges` for an argv.
    static func adminShellAppleScript(executable: String, arguments: [String]) -> String {
        let argv = [executable] + arguments
        let shellCommand = argv.map(posixSingleQuoted).joined(separator: " ")
        let escaped = appleScriptString(shellCommand)
        return "do shell script \"\(escaped)\" with administrator privileges"
    }
}
