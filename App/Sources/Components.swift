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

/// What went wrong and what to do about it, with buttons that do it.
struct ProblemCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    /// The repo or folder it's about.
    var subject: String?
    var diagnosis: Diagnosis
    var repo: RepoProblem?
    /// For the menu: no technical details, and fixes that change the backup are left to the Repos window.
    var compact = false
    @State private var confirming: Diagnosis.Fix?
    @State private var failure: String?
    @State private var copied = false

    private var fixes: [Diagnosis.Fix] {
        compact ? diagnosis.fixes.filter { !$0.needsConfirmation } : diagnosis.fixes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let subject {
                Text(subject).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            Text(diagnosis.title).font(.system(size: 12.5, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            Text(diagnosis.explanation).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Text(diagnosis.advice).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            FlowLayout(spacing: 6) {
                ForEach(fixes, id: \.self) { fix in
                    Button(fix.label) {
                        if fix.needsConfirmation { confirming = fix } else { run(fix) }
                    }
                    .disabled(!model.canRun(fix))
                }
                if compact {
                    if repo != nil {
                        Button("Details") {
                            model.requestRepoProblems()
                            openWindow(id: WindowID.repos)
                            NSApp.activate()
                        }
                    } else {
                        Button("Details") {
                            openWindow(id: WindowID.activity)
                            NSApp.activate()
                        }
                    }
                } else if !diagnosis.technical.isEmpty {
                    Button(copied ? "Copied" : "Copy Details", action: copyDetails)
                }
            }
            .controlSize(.small)
            .padding(.top, 3)
            if let failure {
                Text(failure).font(.system(size: 11.5)).foregroundStyle(Palette.errorText).fixedSize(horizontal: false, vertical: true)
            }
            if !compact, !diagnosis.technical.isEmpty {
                DisclosureGroup("Technical details") {
                    Text(diagnosis.technical)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 3)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.22)))
        .confirmationDialog(confirming.map(confirmationTitle) ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            if let confirming { Button(confirming.label, role: .destructive) { run(confirming) } }
        } message: {
            Text("The backup already on the NAS is kept.")
        }
    }

    private var tint: Color { diagnosis.isTransient ? Palette.orange : Palette.red }

    private func confirmationTitle(_ fix: Diagnosis.Fix) -> String {
        let name = repo?.fullName ?? "this repo"
        return fix == .forgetRepo ? "Forget \(name)?" : "Stop backing up \(name)?"
    }

    private func run(_ fix: Diagnosis.Fix) {
        do {
            try model.perform(fix, repo: repo)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    private func copyDetails() {
        let parts = [subject, diagnosis.title, diagnosis.technical].compactMap { $0 }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(parts.joined(separator: "\n"), forType: .string)
        copied = true
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
