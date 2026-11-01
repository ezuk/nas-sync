import AppKit
import SwiftUI
import SyncCore

// MARK: Layout

/// A Settings page: title, one-line description, then groups.
struct SettingsPage<Content: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 17, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            content
        }
    }
}

/// A titled box of rows, with an optional note under it. `dimmed` shows it but blocks input.
struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    var dimmed = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 2)
            }
            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(rows) { row in
                        if row.id != rows.first?.id { Divider() }
                        row
                    }
                }
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.primary.opacity(0.09)))
            if let footer {
                Text(footer).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
            }
        }
        .opacity(dimmed ? 0.42 : 1)
        .allowsHitTesting(!dimmed)
    }
}

/// A note on its own, like the one shown when Git backups are off.
struct SettingsNote: View {
    var text: String

    var body: some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
    }
}

/// One setting: label and help on the left, the control on the right, and any problem underneath.
/// Hovering shows the setting's name in the file.
struct SettingsRow<Control: View>: View {
    var label: String
    var fileKey: String? = nil
    var help: String? = nil
    /// Set by this folder instead of following All Folders.
    var custom = false
    var error: String? = nil
    var warning: String? = nil
    var onReset: (() -> Void)? = nil
    @ViewBuilder var control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if custom { Circle().fill(Palette.blue).frame(width: 6, height: 6) }
                        Text(label).font(.system(size: 13))
                    }
                    if let help {
                        Text(help).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    control
                    if let onReset {
                        Button("Reset", action: onReset).buttonStyle(.link).font(.system(size: 12.5))
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            if let error { RowMessage(text: error, isError: true) }
            if let warning { RowMessage(text: warning, isError: false) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .help(fileKey ?? "")
    }
}

/// A row whose content spans the full width, like a list of patterns.
struct SettingsWideRow<Content: View>: View {
    var label: String? = nil
    var fileKey: String? = nil
    var help: String? = nil
    var error: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label {
                Text(label).font(.system(size: 13))
            }
            if let help {
                Text(help).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            content
            if let error { RowMessage(text: error, isError: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .help(fileKey ?? "")
    }
}

struct RowMessage: View {
    var text: String
    var isError: Bool

    var body: some View {
        let color = isError ? Palette.red : Palette.orange
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(isError ? Color(red: 0.56, green: 0.11, blue: 0.09) : Color(red: 0.48, green: 0.29, blue: 0))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(color.opacity(isError ? 0.08 : 0.11), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(color.opacity(0.3)))
    }
}

/// A banner at the top of the page.
struct SettingsBanner<Trailing: View>: View {
    enum Kind { case error, info }
    var kind: Kind
    var title: String
    var detail: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if kind == .error { Text("✕").fontWeight(.bold).foregroundStyle(Palette.red) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background((kind == .error ? Palette.red.opacity(0.08) : Palette.blue.opacity(0.1)), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(kind == .error ? Palette.red.opacity(0.28) : .primary.opacity(0.09)))
    }
}

// MARK: Fields

/// A text field that saves when you press Return or leave it. It keeps what you typed if the change is rejected.
struct SettingTextField: View {
    var value: String
    var placeholder: String = ""
    var mono = true
    var width: CGFloat = 270
    var invalid = false
    /// Grey text: the value is inherited.
    var ghost = false
    var commit: (String) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .font(mono ? .system(size: 11.5, design: .monospaced) : .system(size: 12.5))
            .foregroundStyle(ghost ? .secondary : .primary)
            .frame(width: width)
            .focused($focused)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.red, lineWidth: invalid ? 1 : 0))
            .onAppear { text = value }
            .onChange(of: value) { text = value }
            .onSubmit { send() }
            .onChange(of: focused) { if !focused { send() } }
    }

    private func send() {
        if text != value { commit(text) }
    }
}

/// A whole number with arrows.
struct SettingNumberField: View {
    var value: Int
    var range: ClosedRange<Int> = 1...Int.max
    var suffix: String? = nil
    var invalid = false
    var ghost = false
    var commit: (Int) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 12.5).monospacedDigit())
                .foregroundStyle(ghost ? .secondary : .primary)
                .frame(width: 64)
                .focused($focused)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.red, lineWidth: invalid ? 1 : 0))
                .onAppear { text = String(value) }
                .onChange(of: value) { text = String(value) }
                .onSubmit { send() }
                .onChange(of: focused) { if !focused { send() } }
            Stepper("", onIncrement: {
                let n = (Int(text) ?? value)
                if n < range.upperBound { commit(n + 1) }
            }, onDecrement: {
                let n = (Int(text) ?? value)
                if n > range.lowerBound { commit(n - 1) }
            })
            .labelsHidden()
            if let suffix {
                Text(suffix).font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
        }
    }

    private func send() {
        let digits = text.filter(\.isNumber)
        guard let n = Int(digits) else { text = String(value); return }
        if n != value { commit(n) }
    }
}

/// A duration as a number and a unit, written to the file like "30s" or "12h".
struct SettingDurationField: View {
    var value: Interval
    var invalid = false
    var ghost = false
    var commit: (Interval) -> Void

    enum Unit: String, CaseIterable {
        case s, m, h, d, w
        var seconds: Double {
            switch self {
            case .s: 1
            case .m: 60
            case .h: 3600
            case .d: 86400
            case .w: 604_800
            }
        }
        func name(_ n: Int) -> String {
            let base = switch self {
            case .s: "second"
            case .m: "minute"
            case .h: "hour"
            case .d: "day"
            case .w: "week"
            }
            return n == 1 ? base : base + "s"
        }
    }

    /// The largest unit that divides the duration evenly.
    static func parts(_ i: Interval) -> (Int, Unit) {
        let s = Int(i.seconds.rounded())
        guard s > 0 else { return (1, .h) }
        for u in Unit.allCases.reversed() where s % Int(u.seconds) == 0 {
            return (s / Int(u.seconds), u)
        }
        return (s, .s)
    }

    var body: some View {
        let (n, unit) = Self.parts(value)
        HStack(spacing: 4) {
            SettingNumberField(value: n, range: 1...100_000, invalid: invalid, ghost: ghost) { new in
                commit(Interval(seconds: Double(new) * unit.seconds))
            }
            Picker("", selection: Binding(get: { unit }, set: { u in commit(Interval(seconds: Double(n) * u.seconds)) })) {
                ForEach(Unit.allCases, id: \.self) { u in Text(u.name(n)).tag(u) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    /// How a duration is written in the file.
    static func toml(_ i: Interval) -> String {
        let (n, u) = parts(i)
        return "\(n)\(u.rawValue)"
    }
}

/// A local time of day.
struct SettingTimeField: View {
    var value: TimeOfDay
    var commit: (TimeOfDay) -> Void

    var body: some View {
        DatePicker("", selection: Binding(get: {
            Calendar.current.date(bySettingHour: value.hour, minute: value.minute, second: 0, of: Date()) ?? Date()
        }, set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            let t = TimeOfDay(hour: c.hour ?? 0, minute: c.minute ?? 0)
            if t != value { commit(t) }
        }), displayedComponents: .hourAndMinute)
        .labelsHidden()
        .datePickerStyle(.field)
        .fixedSize()
    }
}

struct SettingToggle: View {
    var isOn: Bool
    var set: (Bool) -> Void

    var body: some View {
        Toggle("", isOn: Binding(get: { isOn }, set: set))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
    }
}

// MARK: Lists

/// Removable chips with a field to add more.
struct TokenList: View {
    var items: [String]
    var placeholder: String
    var remove: (Int) -> Void
    var add: (String) -> Void
    /// Extra buttons after the field, like "Add Folder…".
    var buttons: [(String, () -> Void)] = []

    @State private var draft = ""

    var body: some View {
        FlowLayout(spacing: 5) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                HStack(spacing: 4) {
                    Text(Self.visible(item)).font(.system(size: 11.5, design: .monospaced))
                    Button { remove(i) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Remove \(item)")
                }
                .padding(.leading, 7)
                .padding(.trailing, 4)
                .padding(.vertical, 2)
                .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 5))
            }
            HStack(spacing: 6) {
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5, design: .monospaced))
                    .frame(width: 170)
                    .onSubmit {
                        let v = draft.trimmingCharacters(in: .whitespaces)
                        guard !v.isEmpty else { return }
                        draft = ""
                        add(v)
                    }
                ForEach(Array(buttons.enumerated()), id: \.offset) { _, b in
                    Button(b.0, action: b.1)
                }
            }
        }
    }

    /// Shows control characters, such as the carriage return in `Icon\r`, as escapes.
    static func visible(_ s: String) -> String {
        s.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
    }
}

/// One row per entry, with its kind, for a folder's own skip list.
struct PathRowList: View {
    var items: [String]
    var remove: (Int) -> Void

    static func kind(_ item: String) -> String {
        if item.contains(where: { "*?[".contains($0) }) { return "Pattern" }
        return item.hasSuffix("/") ? "Folder" : "File"
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                if i > 0 { Divider() }
                HStack(spacing: 10) {
                    Text(Self.kind(item)).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                    Text(item)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(item)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { remove(i) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .accessibilityLabel("Remove \(item)")
                }
                .padding(.leading, 10)
                .padding(.trailing, 6)
                .padding(.vertical, 4)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.15)))
        .padding(.vertical, 2)
    }
}

/// Patterns worth skipping, offered as dashed chips. A chip goes away once its pattern is in the list.
struct SuggestedPatterns: View {
    var have: [String]
    var add: (String) -> Void

    static let all: [(String, String)] = [
        ("node_modules/", "JavaScript dependencies, reinstalled from package.json"),
        (".git/", "Git history; Git Repos backs repos up separately"),
        (".venv/", "Python virtual environment"),
        ("__pycache__/", "Python bytecode cache"),
        ("build/", "Build output"),
        ("dist/", "Build output"),
        ("*.log", "Log files"),
        (".cache/", "App and tool caches"),
    ]

    /// `**/node_modules` and `node_modules/` count as the same pattern.
    static func normalize(_ s: String) -> String {
        var t = s
        if t.hasPrefix("**/") { t.removeFirst(3) }
        if t.hasSuffix("/") { t.removeLast() }
        return t
    }

    var body: some View {
        let present = Set(have.map(Self.normalize))
        let left = Self.all.filter { !present.contains(Self.normalize($0.0)) }
        if !left.isEmpty {
            FlowLayout(spacing: 6) {
                Text("Suggested:").font(.system(size: 11.5)).foregroundStyle(.secondary)
                ForEach(left, id: \.0) { pattern, why in
                    Button { add(pattern) } label: {
                        Text("+ \(pattern)").font(.system(size: 11.5, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2])).foregroundStyle(.secondary.opacity(0.6)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(why)
                }
            }
            .padding(.top, 2)
        }
    }
}

/// Lays children out in rows, wrapping when the row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y + (row.height - item.size.height) / 2),
                                           proposal: ProposedViewSize(item.size))
            }
        }
    }

    private struct Row {
        var y: CGFloat
        var height: CGFloat = 0
        var width: CGFloat = 0
        var items: [(index: Int, x: CGFloat, size: CGSize)] = []
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row(y: 0)]
        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            var row = rows[rows.count - 1]
            if !row.items.isEmpty, row.width + spacing + size.width > width {
                let y = row.y + row.height + spacing
                rows.append(Row(y: y))
                row = rows[rows.count - 1]
            }
            let x = row.items.isEmpty ? 0 : row.width + spacing
            row.items.append((i, x, size))
            row.width = x + size.width
            row.height = max(row.height, size.height)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.items.isEmpty }
    }
}
