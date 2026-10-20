// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AppKit
import SwiftUI

@main
struct nvidia_card_controlApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandGroup(replacing: .appInfo) {
                Button("About NVIDIA Card Control…") {
                    showStandardAboutPanel()
                }
            }

            CommandMenu("Driver") {
                Button("Refresh Status") {
                    Task { await store.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(store.isBusy)
            }

            CommandGroup(replacing: .help) {
                Button("NVIDIA Card Control Help") {
                    selectionHintAboutDriver()
                }
            }
        }

        Settings {
            Form {
                Section {
                    Text("Driver settings live in the main window sidebar (Display, Video, Performance). This pane is reserved for future app preferences.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 360, minHeight: 160)
        }
    }

    private func showStandardAboutPanel() {
        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "NVIDIA Card Control",
            .credits: NSAttributedString(
                string: String(
                    localized: "Experimental control panel for the NVIDIA Metal driver. Tested on one card in a virtual machine."
                ),
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ),
        ]
        NSApplication.shared.orderFrontStandardAboutPanel(options: options)
    }

    private func selectionHintAboutDriver() {
        let alert = NSAlert()
        alert.messageText = String(localized: "NVIDIA Card Control Help")
        alert.informativeText = String(
            localized: "Use the sidebar to read driver status, change nvmtlctl settings, clear icon caches, restart the desktop, or collect logs. Writes ask for administrator access through osascript. App Sandbox must be off so the app can run nvmtlctl and read /Library/NullMoth."
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }
}
