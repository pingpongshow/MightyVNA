import SwiftUI
import VNACore

struct StatusBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            connectionBadge
                .fixedSize()

            Divider().frame(height: 14)

            Label {
                Text("\(Units.frequencyShort(model.workspace.sweep.start)) – \(Units.frequencyShort(model.workspace.sweep.stop))")
                    .font(Theme.monospace)
            } icon: {
                Image(systemName: "waveform").foregroundStyle(.secondary)
            }

            Text("\(model.workspace.sweep.points) pts")
                .font(Theme.monospace)
                .foregroundStyle(.secondary)

            if model.displayFrame.isFullTwoPort {
                Text("2-port")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.statusGood)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Theme.statusGood.opacity(0.15)))
                    .help("The instrument is measuring S11, S21, S12 and S22.")
            }

            if let info = model.deviceInfo {
                let segments = model.workspace.sweep.segmentCount(for: info.model)
                if segments > 1 {
                    Text("\(segments) segments")
                        .font(Theme.monospaceSmall)
                        .foregroundStyle(Theme.statusWarn)
                        .help("The sweep needs \(segments) hardware passes because the device supports \(info.model.maxHardwarePoints) points at a time.")
                }
            }

            Divider().frame(height: 14)

            calibrationBadge

            if model.workspace.averagingMode != .off {
                Text("AVG \(model.averagingSamples)/\(model.workspace.averagingDepth)")
                    .font(Theme.monospaceSmall)
                    .foregroundStyle(Theme.accent)
            }

            Spacer()

            if model.lastSweepDuration > 0 {
                Text(String(format: "%.2f s/sweep", model.lastSweepDuration))
                    .font(Theme.monospaceSmall)
                    .foregroundStyle(.secondary)
            }

            if let mv = model.batteryMillivolts {
                Label(String(format: "%.2f V", Double(mv) / 1000), systemImage: batteryIcon(mv))
                    .font(Theme.monospaceSmall)
                    .foregroundStyle(mv < 3500 ? Theme.statusWarn : .secondary)
            }

            Text(model.statusMessage)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 300, alignment: .trailing)
                .layoutPriority(-1)

            if model.isSweeping {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(.bar)
    }

    private var connectionBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(statusText)
                .font(.system(size: 11, weight: .medium))
        }
        .help(model.deviceInfo?.banner ?? "No analyser connected")
    }

    private var statusColor: Color {
        switch model.connection {
        case .connected: return Theme.statusGood
        case .connecting: return Theme.statusWarn
        case .failed: return Theme.statusBad
        case .disconnected: return .secondary
        }
    }

    private var statusText: String {
        switch model.connection {
        case .connected(let name): return name
        case .connecting(let name): return "Connecting to \(name)…"
        case .failed: return "Connection failed"
        case .disconnected: return "Disconnected"
        }
    }

    private var calibrationBadge: some View {
        let mode = model.calibration.mode
        let applied = mode != .none && model.workspace.applyHostCalibration
        let label: String = {
            switch mode {
            case .none: return "Uncalibrated"
            case .reflectionOnly: return "CAL 1-port"
            case .forwardResponse: return "CAL response"
            case .fullTwoPort: return "CAL 12-term"
            }
        }()
        return HStack(spacing: 4) {
            Image(systemName: applied ? "checkmark.seal.fill" : "seal")
                .foregroundStyle(applied ? (mode == .fullTwoPort ? Theme.statusGood : Theme.accent) : Color.secondary)
            Text(label)
                .font(Theme.monospaceSmall)
                .fixedSize()
                .foregroundStyle(applied ? (mode == .fullTwoPort ? Theme.statusGood : Theme.accent) : .secondary)
        }
        .help(mode == .none
              ? "No host calibration. The data shown is whatever the instrument returns."
              : "\(mode.displayName) · \(model.calibration.summary) over \(model.calibration.frequencyRangeDescription)\n\n\(mode.explanation)")
    }

    private func batteryIcon(_ mv: Int) -> String {
        switch mv {
        case ..<3500: return "battery.25"
        case ..<3800: return "battery.50"
        case ..<4050: return "battery.75"
        default: return "battery.100"
        }
    }
}
