import SwiftUI
import VNACore

/// Acquisition settings that only exist on the LibreVNA.
struct LibreVNAPanel: View {
    @EnvironmentObject var model: AppModel

    private static let bandwidths: [UInt32] = [10, 30, 100, 300, 1_000, 3_000, 10_000, 30_000, 50_000]

    var body: some View {
        PanelSection(title: "LibreVNA acquisition", systemImage: "dial.high",
                     subtitle: "A narrow IF bandwidth lowers the noise floor; a wide one sweeps faster. Halving the excitation power helps when measuring active devices.") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("IF bandwidth").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { model.libreSettings.ifBandwidth },
                        set: { value in model.updateLibreVNASettings { $0.ifBandwidth = value } }
                    )) {
                        ForEach(available(Self.bandwidths), id: \.self) { value in
                            Text(Units.engineering(Double(value), unit: "Hz", digits: 3)).tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }

                HStack {
                    Text("Excitation").font(.system(size: 11)).foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { Double(model.libreSettings.excitationCdBm) / 100 },
                        set: { value in model.updateLibreVNASettings { $0.excitationCdBm = Int16(value * 100) } }
                    ), in: Double(model.libreSettings.cdbmMin) / 100...Double(model.libreSettings.cdbmMax) / 100)
                    Text(String(format: "%.0f dBm", Double(model.libreSettings.excitationCdBm) / 100))
                        .font(Theme.monospace)
                        .frame(width: 60, alignment: .trailing)
                }

                Toggle("Measure the reverse direction (S12, S22)", isOn: Binding(
                    get: { model.libreSettings.measureReverse },
                    set: { value in model.updateLibreVNASettings { $0.measureReverse = value } }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .help("Turning this off halves the sweep time but drops the reverse path, so the full two-port calibration cannot be applied.")

                Toggle("Logarithmic frequency steps", isOn: Binding(
                    get: { model.libreSettings.logarithmicSweep },
                    set: { value in model.updateLibreVNASettings { $0.logarithmicSweep = value } }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))

                if !model.libreSettings.measureReverse {
                    Text("Reverse measurement is off, so this sweep behaves like a NanoVNA: S11 and S21 only.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.statusWarn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func available(_ values: [UInt32]) -> [UInt32] {
        let settings = model.libreSettings
        var list = values.filter { $0 >= settings.minIFBandwidth && $0 <= settings.maxIFBandwidth }
        if !list.contains(settings.ifBandwidth) { list.append(settings.ifBandwidth) }
        return list.sorted()
    }
}
