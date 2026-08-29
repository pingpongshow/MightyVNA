import SwiftUI
import VNACore

/// Raw serial console: send shell commands and watch the traffic.
struct ConsolePanel: View {
    @EnvironmentObject var model: AppModel
    @State private var commandText = ""
    @State private var history: [String] = []
    @State private var historyIndex = 0

    private let suggestions = ["help", "version", "info", "vbat", "sweep", "frequencies",
                               "data 0", "data 1", "pause", "resume", "cal", "marker",
                               "trace", "edelay", "bandwidth", "power", "capture", "reset"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Serial console")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Toggle("Log traffic", isOn: $model.logTraffic)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10))
                Button("Clear") { model.clearLog() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(model.trafficLog) { entry in
                            HStack(alignment: .top, spacing: 6) {
                                Text(symbol(entry.direction))
                                    .font(Theme.monospaceSmall)
                                    .foregroundStyle(color(entry.direction))
                                    .frame(width: 14, alignment: .leading)
                                Text(entry.text)
                                    .font(Theme.monospaceSmall)
                                    .foregroundStyle(color(entry.direction))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .id(entry.id)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.trafficLog.count) { _, _ in
                    if let last = model.trafficLog.last {
                        withAnimation(.linear(duration: 0.1)) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            .background(Theme.plotBackground)

            Divider()

            HStack(spacing: 6) {
                Text(">").font(Theme.monospace).foregroundStyle(.secondary)
                TextField("Command", text: $commandText)
                    .textFieldStyle(.plain)
                    .font(Theme.monospace)
                    .onSubmit(send)
                Menu {
                    ForEach(suggestions, id: \.self) { command in
                        Button(command) { commandText = command }
                    }
                } label: {
                    Image(systemName: "list.bullet").font(.system(size: 10))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 18)
                Button("Send", action: send)
                    .controlSize(.small)
                    .disabled(!model.session.supportsTextCommands)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            if !model.session.supportsTextCommands {
                Text("The connected device uses the binary V2 protocol, which has no text shell.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
        }
    }

    private func send() {
        let line = commandText.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        history.append(line)
        historyIndex = history.count
        model.sendConsoleCommand(line)
        commandText = ""
    }

    private func symbol(_ direction: TrafficLogEntry.Direction) -> String {
        switch direction {
        case .sent: return "»"
        case .received: return "«"
        case .note: return "•"
        case .error: return "!"
        }
    }

    private func color(_ direction: TrafficLogEntry.Direction) -> Color {
        switch direction {
        case .sent: return Theme.accent
        case .received: return .primary.opacity(0.85)
        case .note: return .secondary
        case .error: return Theme.statusBad
        }
    }
}
