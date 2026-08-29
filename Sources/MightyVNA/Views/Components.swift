import SwiftUI
import VNACore

/// Text field that accepts `144M`, `2.4 GHz`, `50k` and plain numbers.
struct FrequencyField: View {
    var title: String
    @Binding var value: Double
    var onCommit: () -> Void = {}

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(Theme.monospace)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit() } else { text = editableText }
                }
                .onAppear { text = displayText }
                .onChange(of: value) { _, _ in if !focused { text = displayText } }
        }
    }

    private var displayText: String { Units.frequency(value, digits: 9) }
    private var editableText: String { String(format: "%.0f", value) }

    private func commit() {
        if let parsed = Units.parseFrequency(text), parsed > 0 {
            value = parsed
            onCommit()
        }
        text = displayText
    }
}

/// A numeric field with a unit suffix and free-form engineering entry.
struct NumericField: View {
    var title: String
    @Binding var value: Double
    var unit: String = ""
    var format: String = "%.4g"
    var width: CGFloat = 46
    var onCommit: () -> Void = {}

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: width, alignment: .leading)
            }
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(Theme.monospace)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                .onAppear { text = display }
                .onChange(of: value) { _, _ in if !focused { text = display } }
            if !unit.isEmpty {
                Text(unit).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private var display: String { String(format: format, value) }

    private func commit() {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
        if let parsed = Double(cleaned) {
            value = parsed
            onCommit()
        } else if let parsed = Units.parseFrequency(cleaned) {
            value = parsed
            onCommit()
        }
        text = display
    }
}

/// A labelled read-only value row.
struct ValueRow: View {
    var label: String
    var value: String
    var color: Color = .primary
    var help: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(Theme.readout)
                .foregroundStyle(color)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
        .help(help ?? "")
    }
}

/// Section wrapper used throughout the inspector panels.
struct PanelSection<Content: View>: View {
    var title: String
    var systemImage: String? = nil
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
            }
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.04)))
    }
}

/// Small pill button used for compact toolbars inside panels.
struct PillButton: View {
    var title: String
    var systemImage: String? = nil
    var tint: Color = Theme.accent
    var isProminent: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 10)) }
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isProminent ? tint.opacity(0.9) : tint.opacity(0.15))
            )
            .foregroundStyle(isProminent ? Color.white : tint)
        }
        .buttonStyle(.plain)
    }
}
