import SwiftUI
import VNACore

/// Designs L-networks that match the measured load to the system impedance.
struct MatchingTool: View {
    @EnvironmentObject var model: AppModel
    @State private var useMarker = true
    @State private var manualFrequency: Double = 145e6
    @State private var targetImpedance: Double = 50

    var body: some View {
        PanelSection(title: "Impedance matching", systemImage: "arrow.triangle.merge",
                     subtitle: "Two-element L-networks that transform the measured load to the target impedance at one frequency.") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Use the active marker", isOn: $useMarker)
                    .toggleStyle(.checkbox).font(.system(size: 11))
                if !useMarker {
                    FrequencyField(title: "Freq", value: $manualFrequency)
                }
                NumericField(title: "Target", value: $targetImpedance, unit: "Ω", format: "%.2f", width: 40)

                Divider()

                if let context = measurement {
                    ValueRow(label: "At", value: Units.frequency(context.frequency))
                    ValueRow(label: "Measured Z",
                             value: String(format: "%.2f %@ j%.2f Ω", context.z.re, context.z.im < 0 ? "−" : "+", abs(context.z.im)))
                    ValueRow(label: "SWR", value: Units.fixed(RF.swr(context.gamma), 3))

                    let solutions = MatchingNetwork.lNetworks(load: context.z, z0: targetImpedance,
                                                             frequency: context.frequency)
                    if solutions.isEmpty {
                        Text("No two-element L-network reaches this target. Try a different frequency, or a three-element network.")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.statusWarn)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(solutions) { solution in
                            solutionCard(solution, load: context.z, frequency: context.frequency)
                        }
                    }

                    if let quarterWave = MatchingNetwork.quarterWaveImpedance(load: context.z, z0: targetImpedance) {
                        Divider()
                        ValueRow(label: "¼-wave transformer", value: Units.ohms(quarterWave),
                                 help: "Characteristic impedance of a quarter-wavelength line that matches this (nearly real) load.")
                        ValueRow(label: "Line length (VF \(Units.fixed(model.workspace.timeDomain.velocityFactor, 2)))",
                                 value: Units.distance(speedOfLight * model.workspace.timeDomain.velocityFactor / context.frequency / 4))
                    }
                } else {
                    Text("Run a sweep and place a marker to design a matching network.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private struct Measurement {
        var frequency: Double
        var gamma: Complex
        var z: Complex
    }

    private var measurement: Measurement? {
        let frame = model.displayFrame
        guard !frame.isEmpty else { return nil }
        let frequency: Double
        if useMarker, let index = model.activeMarkerIndex() {
            frequency = model.workspace.markers[index].frequency
        } else {
            frequency = manualFrequency
        }
        let index = frame.nearestIndex(to: frequency)
        let gamma = frame.s11[index]
        return Measurement(frequency: frame.frequencies[index], gamma: gamma,
                           z: RF.impedance(gamma, z0: frame.z0))
    }

    private func solutionCard(_ solution: MatchingSolution, load: Complex, frequency: Double) -> some View {
        let result = MatchingNetwork.resultingImpedance(load: load, solution: solution, frequency: frequency)
        let residualSWR = RF.swr(RF.reflection(fromImpedance: result, z0: targetImpedance))
        return VStack(alignment: .leading, spacing: 3) {
            Text(solution.topology)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.accent)
            ForEach(Array(solution.components.enumerated()), id: \.offset) { _, component in
                HStack(spacing: 6) {
                    Image(systemName: component.kind == .inductor ? "scribble" : "capsule.portrait")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(component.description)
                        .font(Theme.monospaceSmall)
                        .textSelection(.enabled)
                }
            }
            HStack(spacing: 10) {
                Text("Q \(Units.fixed(solution.loadedQ, 2))")
                Text("BW ≈ \(Units.fixed(solution.fractionalBandwidth * 100, 1))%")
                Text("resid. SWR \(Units.fixed(residualSWR, 3))")
            }
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
    }
}
