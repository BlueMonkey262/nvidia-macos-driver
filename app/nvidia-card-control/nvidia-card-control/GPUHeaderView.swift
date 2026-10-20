// Copyright (c) 2026 BlueMonkey
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import SwiftUI

/// A plain outline of a graphics card: mounting bracket on the left, rounded body with two or three fans,
/// and the PCIe edge connector (with its key gap) along the bottom.
struct GPUOutline: Shape {
    var fanCount = 2

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let bracketWidth = rect.width * 0.035
        let connectorHeight = rect.height * 0.14

        // Mounting bracket: full height, at the end of the card.
        path.addRect(CGRect(x: rect.minX, y: rect.minY, width: bracketWidth, height: rect.height))

        // Card body.
        let body = CGRect(
            x: rect.minX + bracketWidth * 1.6,
            y: rect.minY,
            width: rect.width - bracketWidth * 1.6,
            height: rect.height - connectorHeight
        )
        let corner = body.height * 0.14
        path.addRoundedRect(in: body, cornerSize: CGSize(width: corner, height: corner))

        // PCIe edge connector: two groups of contacts split by the key gap.
        let connectorTop = body.maxY
        let start = body.minX + body.width * 0.08
        path.addRect(CGRect(x: start, y: connectorTop, width: body.width * 0.26, height: connectorHeight))
        path.addRect(CGRect(x: start + body.width * 0.29, y: connectorTop, width: body.width * 0.18, height: connectorHeight))

        // Fans.
        let three = fanCount >= 3
        let fanDiameter = min(body.height * 0.88, body.width * (three ? 0.31 : 0.45))
        for fraction in three ? [0.17, 0.5, 0.83] : [0.26, 0.74] {
            let fan = CGRect(
                x: body.minX + body.width * fraction - fanDiameter / 2,
                y: body.midY - fanDiameter / 2,
                width: fanDiameter,
                height: fanDiameter
            )
            path.addEllipse(in: fan)
            let hub = fanDiameter * 0.16
            path.addEllipse(in: CGRect(x: fan.midX - hub / 2, y: fan.midY - hub / 2, width: hub, height: hub))
        }
        return path
    }
}

/// How many fans to draw. Cards in the 80 and 90 tiers are usually three-fan designs and the rest two-fan.
/// This is a guess from the model name for the picture only; some cards differ.
nonisolated enum GPUFanLayout {
    static func fanCount(forGPUNamed name: String) -> Int {
        guard let model = modelNumber(in: name) else { return 2 }
        return model % 100 >= 80 ? 3 : 2
    }

    /// The first run of three or four digits after "RTX" or "GTX", e.g. 2060 in "GeForce RTX 2060 SUPER".
    private static func modelNumber(in name: String) -> Int? {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" })
        guard let index = words.firstIndex(where: { $0 == "RTX" || $0 == "GTX" }) else { return nil }
        for word in words[words.index(after: index)...] {
            let digits = word.prefix(while: \.isNumber)
            if digits.count >= 3, digits.count <= 4, let value = Int(digits) { return value }
        }
        return nil
    }
}

struct GPUHeaderView: View {
    let gpuName: String
    let telemetry: GPUTelemetry

    var body: some View {
        VStack(spacing: 16) {
            GPUOutline(fanCount: GPUFanLayout.fanCount(forGPUNamed: gpuName))
                .stroke(.tint, style: StrokeStyle(lineWidth: 3, lineJoin: .round))
                .aspectRatio(2.4, contentMode: .fit)
                .frame(maxWidth: 320)
                .accessibilityHidden(true)

            Text(gpuName.isEmpty ? String(localized: "No GPU found") : gpuName)
                .font(.title3.weight(.semibold))

            HStack(spacing: 12) {
                tile("Temperature", value: telemetry.temperatureC.map { "\(Int($0.rounded())) °C" })
                tile("Fan", value: fanText)
                tile("Core clock", value: telemetry.coreClockMHz.map { "\($0) MHz" })
                tile("Power", value: telemetry.powerWatts.map { "\(Int($0.rounded())) W" })
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var fanText: String? {
        switch (telemetry.fanRPM, telemetry.fanPercent) {
        case let (rpm?, percent?): return "\(rpm) rpm (\(percent)%)"
        case let (rpm?, nil): return "\(rpm) rpm"
        case let (nil, percent?): return "\(percent)%"
        default: return nil
        }
    }

    private func tile(_ title: LocalizedStringKey, value: String?) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value ?? "—")
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

#Preview("Two fans") {
    GPUHeaderView(gpuName: "NVIDIA GeForce RTX 2060 SUPER", telemetry: .previewSample)
        .padding()
        .frame(width: 520)
}

#Preview("Three fans") {
    GPUHeaderView(gpuName: "NVIDIA GeForce RTX 3090", telemetry: .previewSample)
        .padding()
        .frame(width: 520)
}
