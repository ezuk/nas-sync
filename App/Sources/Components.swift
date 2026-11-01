import AppKit
import SwiftUI
import SyncCore

enum Palette {
    static let green = Color(red: 0.157, green: 0.655, blue: 0.271)
    static let orange = Color(red: 0.898, green: 0.541, blue: 0.0)
    static let red = Color(red: 0.878, green: 0.208, blue: 0.169)
    static let blue = Color(red: 0.039, green: 0.424, blue: 1.0)
    static let grey = Color(red: 0.557, green: 0.557, blue: 0.576)
    static let purple = Color(red: 0.478, green: 0.110, blue: 0.455)

    static let errorText = Color(light: Color(red: 0.56, green: 0.11, blue: 0.09), dark: Color(red: 1, green: 0.62, blue: 0.58))
    static let warningText = Color(light: Color(red: 0.48, green: 0.29, blue: 0), dark: Color(red: 1, green: 0.78, blue: 0.42))
    static let tomlHeader = Color(light: Color(red: 0.04, green: 0.31, blue: 0.47), dark: Color(red: 0.47, green: 0.76, blue: 0.96))
    static let tomlKey = Color(light: Color(red: 0.61, green: 0.14, blue: 0.58), dark: Color(red: 0.91, green: 0.62, blue: 0.89))
    static let tomlString = Color(light: Color(red: 0.77, green: 0.10, blue: 0.09), dark: Color(red: 1, green: 0.57, blue: 0.52))
}

extension Color {
    /// A color with separate values for light and dark mode.
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            NSColor(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        })
    }
}

struct StatusDot: View {
    var color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

struct Chip: View {
    var color: Color
    var text: String

    var body: some View {
        HStack(spacing: 5) {
            StatusDot(color: color, size: 6)
            Text(text)
        }
        .font(.system(size: 11))
        .foregroundStyle(.primary.opacity(0.8))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.primary.opacity(0.055), in: Capsule())
    }
}

/// Small coloured label like NEW, CHANGED or FAILED.
struct Tag: View {
    enum Style { case new, changed, archived, same, bad, local }
    var text: String
    var style: Style

    var colors: (Color, Color) {
        switch style {
        case .new: (Palette.green.opacity(0.14), Color(red: 0.11, green: 0.42, blue: 0.19))
        case .changed: (Palette.blue.opacity(0.12), Color(red: 0.04, green: 0.31, blue: 0.72))
        case .archived: (Palette.orange.opacity(0.15), Color(red: 0.54, green: 0.33, blue: 0))
        case .same: (Color.primary.opacity(0.06), Color.secondary)
        case .bad: (Palette.red.opacity(0.12), Color(red: 0.61, green: 0.11, blue: 0.08))
        case .local: (Palette.purple.opacity(0.1), Palette.purple)
        }
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(colors.1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(colors.0, in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
    }
}

struct ProgressStrip: View {
    var fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                Capsule().fill(Palette.blue).frame(width: max(4, geo.size.width * fraction))
            }
        }
        .frame(height: 5)
        .animation(.easeOut(duration: 0.3), value: fraction)
    }
}

/// Big number with a caption (Activity window).
struct KPI: View {
    var value: String
    var label: String
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 20, weight: .semibold)).monospacedDigit().foregroundStyle(color)
            Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.background, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.primary.opacity(0.09)))
    }
}

extension JobStatus {
    var dotColor: Color {
        switch state {
        case .running: Palette.blue
        case .error: Palette.red
        case .stale: Palette.orange
        case .queued, .away, .holdingOff, .paused: Palette.grey
        case .idle: lastSuccess == nil ? Palette.grey : Palette.green
        }
    }
}

extension RunRecord {
    var dotColor: Color {
        switch outcome {
        case .success: kind == .away ? Palette.grey : Palette.green
        case .warning: Palette.orange
        case .failed, .blocked: Palette.red
        case .cancelled: Palette.grey
        }
    }
}
