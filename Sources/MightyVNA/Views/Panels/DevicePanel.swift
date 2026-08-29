import SwiftUI
import VNACore

struct DevicePanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        PanelSection(title: "Analyser", systemImage: "cable.connector") {
            VStack(alignment: .leading, spacing: 8) {
                devicePicker
                protocolPicker
                connectionButtons
                selectedDetail
                if let info = model.deviceInfo {
                    Divider()
                    DeviceInfoRows(info: info, batteryMillivolts: model.batteryMillivolts)
                    deviceActions
                }
                failureMessage
                emptyHint
            }
        }
    }

    // MARK: - Pieces

    private var devicePicker: some View {
        HStack(spacing: 6) {
            Picker("", selection: Binding(
                get: { model.selectedDevice?.id ?? "" },
                set: { id in model.selectedDevice = model.devices.first { $0.id == id } }
            )) {
                if model.devices.isEmpty {
                    Text("No analysers found").tag("")
                }
                ForEach(model.devices) { device in
                    Text(label(for: device)).tag(device.id)
                }
            }
            .labelsHidden()
            .disabled(model.connection.isConnected)

            Button {
                model.refreshPorts()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Rescan for serial ports and USB instruments")
        }
    }

    private var protocolPicker: some View {
        Picker("Protocol", selection: $model.connectionPreference) {
            ForEach(ConnectionPreference.allCases) { preference in
                Text(preference.displayName).tag(preference)
            }
        }
        .font(.system(size: 11))
        .disabled(model.connection.isConnected || (model.selectedDevice?.isUSB ?? false))
        .help(model.selectedDevice?.isUSB == true
              ? "Raw-USB instruments identify themselves, so there is nothing to choose."
              : "Leave on automatic unless a device is misdetected.")
    }

    private var connectionButtons: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if model.connection.isConnected {
                    PillButton(title: "Disconnect", systemImage: "eject", tint: Theme.statusBad) {
                        model.disconnect()
                    }
                } else {
                    PillButton(title: "Connect", systemImage: "bolt.horizontal", isProminent: true) {
                        model.connect()
                    }
                    .disabled(model.selectedDevice == nil || model.connection.isBusy)
                }
            }
            HStack(spacing: 6) {
                PillButton(title: "NanoVNA sim", systemImage: "waveform.badge.plus", tint: .purple) {
                    model.connectSimulator()
                }
                .help("Synthetic one-port-plus-response analyser: a dual-band antenna and a bandpass filter")
                PillButton(title: "LibreVNA sim", systemImage: "square.on.square.badge.person.crop", tint: .teal) {
                    model.connectLibreVNASimulator()
                }
                .help("Synthetic full two-port analyser, so S12, S22 and the 12-term calibration can be explored without hardware")
            }
        }
    }

    @ViewBuilder
    private var selectedDetail: some View {
        if let device = model.selectedDevice, !model.connection.isConnected {
            Text(device.detail)
                .font(Theme.monospaceSmall)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var deviceActions: some View {
        HStack(spacing: 6) {
            PillButton(title: "Screenshot", systemImage: "camera") {
                model.captureDeviceScreen()
            }
            .disabled(!model.session.supportsScreenCapture)
            PillButton(title: "Battery", systemImage: "battery.100") {
                model.refreshBattery()
            }
            .disabled(!(model.deviceInfo?.model.supportsBattery ?? false))
        }
    }

    @ViewBuilder
    private var failureMessage: some View {
        if case .failed(let message) = model.connection {
            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(Theme.statusBad)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var emptyHint: some View {
        if model.devices.isEmpty && !model.connection.isConnected {
            Text("No analysers detected. Connect the instrument over USB and switch it on. "
                 + "NanoVNA units appear as a serial port (/dev/cu.usbmodem…); a LibreVNA appears as a "
                 + "raw USB device and needs no serial driver.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func label(for device: DiscoveredDevice) -> String {
        switch device {
        case .serial(let port):
            return "\(port.usbProductName ?? port.name) — \(port.name)"
        case .usb(let usb):
            return "\(usb.displayName) — USB"
        }
    }
}

/// Read-only summary of the connected instrument.
private struct DeviceInfoRows: View {
    var info: DeviceInfo
    var batteryMillivolts: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ValueRow(label: "Model", value: info.model.name)
            ValueRow(label: "Range", value: info.model.frequencyRangeDescription)
            ValueRow(label: "Max points", value: "\(info.model.maxHardwarePoints)")
            ValueRow(label: "Measures",
                     value: info.model.isFullTwoPort ? "S11 S21 S12 S22" : "S11 S21",
                     color: info.model.isFullTwoPort ? Theme.statusGood : .primary,
                     help: info.model.isFullTwoPort
                        ? "A true two-port instrument: the reverse direction is measured, so a full 12-term calibration is possible."
                        : "This instrument measures the forward direction only. S12 and S22 are not available.")
            if !info.firmwareVersion.isEmpty {
                ValueRow(label: "Firmware", value: info.firmwareVersion)
            }
            ValueRow(label: "Protocol", value: info.model.wireProtocol.displayName)
            if let mv = batteryMillivolts {
                ValueRow(label: "Battery", value: String(format: "%.2f V", Double(mv) / 1000),
                         color: mv < 3500 ? Theme.statusWarn : .primary)
            }
            if let screen = info.screen {
                ValueRow(label: "Screen", value: screen.description)
            }
            if !info.model.notes.isEmpty {
                Text(info.model.notes)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
