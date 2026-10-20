// Copyright (c) 2026 BlueMonkey
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import SwiftUI

/// Separate window id for the streaming encoder test pattern (`openWindow`).
enum StreamPatternWindow {
    static let id = "stream-pattern"
}

/// Full-window animated test pattern for streaming encode exercises.
struct StreamPatternView: View {
    @State private var noiseEnabled = true
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
                Canvas { context, size in
                    StreamPatternRenderer.draw(
                        into: &context,
                        size: size,
                        date: timeline.date,
                        noiseEnabled: noiseEnabled
                    )
                }
                .ignoresSafeArea()
            }

            VStack(alignment: .trailing, spacing: 8) {
                Toggle("Noise", isOn: $noiseEnabled)
                    .toggleStyle(.switch)
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityLabel(String(localized: "Noise"))
                    .accessibilityHint(String(localized: "Show or hide the random noise band"))

                Text("Esc or ⌘W closes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            .padding(12)
        }
        .frame(minWidth: 640, minHeight: 360)
        .background(Color.black)
        .focusable()
        .onExitCommand {
            dismissWindow(id: StreamPatternWindow.id)
        }
        .accessibilityLabel(String(localized: "GPU Control test pattern"))
    }
}

/// Draws the recognisable moving pattern; pure geometry, no private API.
enum StreamPatternRenderer {
    static func draw(
        into context: inout GraphicsContext,
        size: CGSize,
        date: Date,
        noiseEnabled: Bool
    ) {
        let t = date.timeIntervalSinceReferenceDate
        let cycleLength = 5.0
        let cutLength = 1.0
        let sceneIndex = Int(floor(t / cycleLength))
        let phaseInCycle = t - (Double(sceneIndex) * cycleLength)

        if phaseInCycle < cutLength {
            let cutColor = flatCutColor(sceneIndex: sceneIndex)
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(cutColor)
            )
            drawOverlayChrome(into: &context, size: size, date: date, sceneIndex: sceneIndex, cut: true)
            return
        }

        let patternTime = t
        drawBackground(into: &context, size: size, sceneIndex: sceneIndex)
        drawScrollingColourBars(into: &context, size: size, time: patternTime, sceneIndex: sceneIndex)
        if noiseEnabled {
            drawNoiseBand(into: &context, size: size, time: patternTime, sceneIndex: sceneIndex)
        }
        drawScrollingText(into: &context, size: size, time: patternTime, sceneIndex: sceneIndex)
        drawMovingCircle(into: &context, size: size, time: patternTime, sceneIndex: sceneIndex)
        drawOverlayChrome(into: &context, size: size, date: date, sceneIndex: sceneIndex, cut: false)
    }

    private static func flatCutColor(sceneIndex: Int) -> Color {
        let palette: [Color] = [
            Color(red: 0.12, green: 0.12, blue: 0.14),
            Color(red: 0.75, green: 0.15, blue: 0.12),
            Color(red: 0.10, green: 0.55, blue: 0.20),
            Color(red: 0.10, green: 0.25, blue: 0.75),
            Color(red: 0.85, green: 0.75, blue: 0.10),
        ]
        return palette[abs(sceneIndex) % palette.count]
    }

    private static func drawBackground(into context: inout GraphicsContext, size: CGSize, sceneIndex: Int) {
        let base: Color
        switch abs(sceneIndex) % 3 {
        case 0:
            base = Color(red: 0.05, green: 0.05, blue: 0.08)
        case 1:
            base = Color(red: 0.08, green: 0.05, blue: 0.05)
        default:
            base = Color(red: 0.04, green: 0.07, blue: 0.06)
        }
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(base))
    }

    private static func drawScrollingColourBars(
        into context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        sceneIndex: Int
    ) {
        let barColors: [Color] = [
            .white,
            .yellow,
            .cyan,
            .green,
            .magenta,
            .red,
            .blue,
            Color(white: 0.2),
        ]
        let barCount = barColors.count
        let barWidth = max(8, size.width / CGFloat(barCount))
        let scroll = CGFloat(time * 120).truncatingRemainder(dividingBy: barWidth * CGFloat(barCount))
        let rotation = Double(sceneIndex % 4) * 0.0

        _ = rotation
        let barsTop = size.height * 0.08
        let barsHeight = size.height * 0.42

        for i in -1..<(barCount + 2) {
            let x = CGFloat(i) * barWidth - scroll
            let color = barColors[((i % barCount) + barCount) % barCount]
            let rect = CGRect(x: x, y: barsTop, width: barWidth + 1, height: barsHeight)
            context.fill(Path(rect), with: .color(color))
        }
    }

    private static func drawNoiseBand(
        into context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        sceneIndex: Int
    ) {
        let bandTop = size.height * 0.52
        let bandHeight = size.height * 0.14
        let cell: CGFloat = 6
        let columns = Int(ceil(size.width / cell))
        let rows = Int(ceil(bandHeight / cell))
        let frame = Int(time * 60)

        let seed = UInt64(UInt(bitPattern: frame)) &* 73856093 &+ UInt64(UInt(bitPattern: sceneIndex)) &* 19349663
        var generator = SeededGenerator(seed: seed)

        for row in 0..<rows {
            for column in 0..<columns {
                let brightness = Double.random(in: 0...1, using: &generator)
                let rect = CGRect(
                    x: CGFloat(column) * cell,
                    y: bandTop + CGFloat(row) * cell,
                    width: cell,
                    height: cell
                )
                context.fill(Path(rect), with: .color(Color(white: brightness)))
            }
        }
    }

    private static func drawScrollingText(
        into context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        sceneIndex: Int
    ) {
        let lines = [
            "GPU CONTROL TEST PATTERN",
            "SCENE \(sceneIndex)  SCROLL  MOTION  EDGES",
            "STREAM ENCODER STRESS  COLOUR BARS  NOISE",
            "FRAME CLOCK  CUT EVERY 5s",
        ]
        let textY0 = size.height * 0.70
        let lineHeight: CGFloat = 22
        let scroll = CGFloat(time * 80)

        for (index, line) in lines.enumerated() {
            let y = textY0 + CGFloat(index) * lineHeight
            let widthEstimate = CGFloat(line.count) * 9
            let x = size.width - (scroll + CGFloat(index) * 40).truncatingRemainder(dividingBy: size.width + widthEstimate)
            let shadow = Text(line)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(.black.opacity(0.55))
            context.draw(shadow, at: CGPoint(x: x + 1, y: y + 1), anchor: .leading)
            let text = Text(line)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
            context.draw(text, at: CGPoint(x: x, y: y), anchor: .leading)
        }
    }

    private static func drawMovingCircle(
        into context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        sceneIndex: Int
    ) {
        let radius: CGFloat = min(size.width, size.height) * 0.06
        let cx = size.width * 0.5 + cos(time * 1.7 + Double(sceneIndex)) * (size.width * 0.35)
        let cy = size.height * 0.38 + sin(time * 2.3 + Double(sceneIndex) * 0.7) * (size.height * 0.18)
        let rect = CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: rect), with: .color(.orange))
        context.stroke(Path(ellipseIn: rect.insetBy(dx: 2, dy: 2)), with: .color(.white), lineWidth: 2)
    }

    private static func drawOverlayChrome(
        into context: inout GraphicsContext,
        size: CGSize,
        date: Date,
        sceneIndex: Int,
        cut: Bool
    ) {
        let frame = Int(date.timeIntervalSinceReferenceDate * 60)
        let clock = formatClock(date)
        let label = cut
            ? "CUT  scene \(sceneIndex)  \(clock)"
            : "FRAME \(frame)  scene \(sceneIndex)  \(clock)"
        let text = Text(label)
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundColor(.white)
        context.draw(text, at: CGPoint(x: 12, y: 14), anchor: .topLeading)

        let badge = Text("TEST PATTERN")
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundColor(.yellow)
        context.draw(badge, at: CGPoint(x: size.width - 12, y: size.height - 14), anchor: .bottomTrailing)
    }

    private static func formatClock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
}

/// Deterministic RNG so noise is stable within a frame and changes each frame.
nonisolated struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

#Preview {
    StreamPatternView()
        .frame(width: 960, height: 540)
}
