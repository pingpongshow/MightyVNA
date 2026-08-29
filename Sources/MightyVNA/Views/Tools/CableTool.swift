import SwiftUI
import VNACore

/// Cable length, velocity factor, loss and distance-to-fault.
struct CableTool: View {
    @EnvironmentObject var model: AppModel
    @State private var knownLength: Double = 1.0
    @State private var selectedCable: String = "RG-58 C/U"

    var body: some View {
        PanelSection(title: "Cable tools", systemImage: "cable.coaxial",
                     subtitle: "Measure a coax run by connecting it to CH0 with the far end open or shorted.") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Cable", selection: $selectedCable) {
                    ForEach(CableTools.commonCables) { Text($0.name).tag($0.name) }
                }
                .font(.system(size: 11))
                .onChange(of: selectedCable) { _, name in
                    if let cable = CableTools.commonCables.first(where: { $0.name == name }) {
                        model.workspace.timeDomain.velocityFactor = cable.velocityFactor
                    }
                }

                NumericField(title: "VF", value: $model.workspace.timeDomain.velocityFactor,
                             format: "%.4f", width: 34)

                Divider()

                let tdr = currentTDR
                if let fault = firstDiscontinuity(tdr) {
                    ValueRow(label: "Distance to end/fault", value: Units.distance(fault.distance),
                             color: Theme.accent)
                    ValueRow(label: "Round-trip delay", value: Units.time(fault.time))
                    ValueRow(label: "Reflection there", value: Units.fixed(fault.magnitude, 3))
                    Divider()

                    NumericField(title: "Known", value: $knownLength, unit: "m", format: "%.4f", width: 40)
                    if let vf = CableTools.velocityFactor(physicalLength: knownLength, roundTripDelay: fault.time) {
                        ValueRow(label: "Implied VF", value: Units.fixed(vf, 4),
                                 help: "Enter the true physical length above and this is the velocity factor that matches the measurement.")
                        PillButton(title: "Use this VF", systemImage: "arrow.down.circle") {
                            model.workspace.timeDomain.velocityFactor = vf
                        }
                    }
                } else {
                    Text("Connect the cable to CH0 and run a sweep. A wide sweep starting near the device's lowest frequency gives the best result.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                if let loss = averageLoss {
                    ValueRow(label: "One-way loss (measured)", value: String(format: "%.2f dB", loss.value),
                             help: "Derived from the reflection magnitude with the far end open or shorted: half the round-trip loss.")
                    ValueRow(label: "at", value: Units.frequency(loss.frequency))
                }
                if let cable = CableTools.commonCables.first(where: { $0.name == selectedCable }) {
                    let f = model.displayFrame.isEmpty ? 100e6 : model.displayFrame.centerFrequency
                    ValueRow(label: "Catalogue loss",
                             value: String(format: "%.2f dB", CableTools.estimatedLoss(cable: cable, lengthMetres: knownLength, frequency: f)),
                             help: "Typical matched loss for \(cable.name) at \(Units.frequencyShort(f)) over \(Units.distance(knownLength)).")
                    ValueRow(label: "Nominal Z₀", value: Units.ohms(cable.impedance))
                }
            }
        }
    }

    private var currentTDR: TimeDomainResult {
        guard !model.displayFrame.isEmpty else { return .empty }
        var settings = model.workspace.timeDomain
        settings.mode = .lowpassStep
        return TimeDomain.transform(frame: model.displayFrame, channel: .s11, settings: settings)
    }

    private func firstDiscontinuity(_ result: TimeDomainResult) -> (distance: Double, time: Double, magnitude: Double)? {
        guard result.impulse.count > 8 else { return nil }
        let values = Array(result.impulse[3...]).map { abs($0) }
        guard let peak = TraceAnalysis.indexOfMaximum(values) else { return nil }
        let index = peak + 3
        guard index < result.distance.count else { return nil }
        return (result.distance[index], result.time[index], result.impulse[index])
    }

    private var averageLoss: (value: Double, frequency: Double)? {
        let frame = model.displayFrame
        guard !frame.isEmpty else { return nil }
        let index = frame.count / 2
        let loss = -RF.dB(frame.s11[index].magnitude) / 2
        guard loss.isFinite, loss >= 0 else { return nil }
        return (loss, frame.frequencies[index])
    }
}
