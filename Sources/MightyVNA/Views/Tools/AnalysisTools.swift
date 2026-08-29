import SwiftUI
import VNACore

/// Antenna resonance, bandwidth and impedance summary.
struct AntennaTool: View {
    @EnvironmentObject var model: AppModel
    @State private var swrThreshold: Double = 2.0

    var body: some View {
        PanelSection(title: "Antenna analysis", systemImage: "antenna.radiowaves.left.and.right",
                     subtitle: "Resonance, usable bandwidth and feedpoint impedance from the S11 sweep.") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("SWR limit").font(.system(size: 11)).foregroundStyle(.secondary)
                    Slider(value: $swrThreshold, in: 1.2...6, step: 0.1)
                    Text(Units.fixed(swrThreshold, 1)).font(Theme.monospace).frame(width: 30)
                }

                let report = AntennaAnalysis.analyse(s11: model.displayFrame.s11,
                                                     frequencies: model.displayFrame.frequencies,
                                                     z0: model.displayFrame.z0,
                                                     swrThreshold: swrThreshold)
                if !report.isValid {
                    Text("Run a sweep across the antenna's band to see the analysis.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    ValueRow(label: "Resonance (X = 0)", value: Units.frequency(report.resonantFrequency),
                             color: Theme.accent)
                    ValueRow(label: "Z at resonance",
                             value: String(format: "%.1f %@ j%.1f Ω", report.impedanceAtResonance.re,
                                           report.impedanceAtResonance.im < 0 ? "−" : "+",
                                           abs(report.impedanceAtResonance.im)))
                    Divider()
                    ValueRow(label: "Minimum SWR", value: Units.fixed(report.minimumSWR, 3),
                             color: report.minimumSWR < 1.5 ? Theme.statusGood
                                 : (report.minimumSWR < 2.5 ? Theme.statusWarn : Theme.statusBad))
                    ValueRow(label: "at", value: Units.frequency(report.minimumSWRFrequency))
                    ValueRow(label: "Return loss", value: String(format: "%.2f dB", report.returnLossAtMinimum))
                    ValueRow(label: "Z there",
                             value: String(format: "%.1f %@ j%.1f Ω", report.impedanceAtMinimumSWR.re,
                                           report.impedanceAtMinimumSWR.im < 0 ? "−" : "+",
                                           abs(report.impedanceAtMinimumSWR.im)))
                    Divider()
                    if report.bandwidth > 0 {
                        ValueRow(label: "SWR ≤ \(Units.fixed(swrThreshold, 1)) band",
                                 value: "\(Units.frequencyShort(report.bandwidthLower)) – \(Units.frequencyShort(report.bandwidthUpper))")
                        ValueRow(label: "Bandwidth", value: Units.frequency(report.bandwidth), color: Theme.accent)
                        ValueRow(label: "Loaded Q", value: Units.fixed(report.q, 2))
                    } else {
                        Text("The SWR never crosses \(Units.fixed(swrThreshold, 1)) inside this sweep, so no bandwidth could be measured. Widen the sweep or raise the limit.")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.statusWarn)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if report.resonantFrequency > 0 {
                        Divider()
                        let target = model.workspace.sweep.center
                        let error = (report.resonantFrequency - target) / target
                        Text(tuningAdvice(error: error, report: report))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func tuningAdvice(error: Double, report: AntennaAnalysis.Report) -> String {
        let percent = abs(error) * 100
        if percent < 0.5 {
            return "Resonance sits within 0.5 % of the sweep centre."
        }
        let direction = error > 0 ? "above" : "below"
        let action = error > 0 ? "lengthening" : "shortening"
        return String(format: "Resonance is %.1f %% %@ the sweep centre. For a simple resonant element, %@ it by roughly %.1f %% moves it towards the centre.",
                      percent, direction, action, percent)
    }
}

/// Filter, amplifier and attenuator characterisation from S21.
struct FilterTool: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        PanelSection(title: "Filter & network analysis", systemImage: "waveform.badge.magnifyingglass",
                     subtitle: "Insertion loss, bandwidth and shape from the S21 sweep. Calibrate with a through connection first for meaningful absolute numbers.") {
            VStack(alignment: .leading, spacing: 6) {
                let report = FilterAnalysis.analyse(s21: model.displayFrame.s21,
                                                    frequencies: model.displayFrame.frequencies)
                if !report.isValid {
                    Text("Connect the device under test between CH0 and CH1, then run a sweep across its passband.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ValueRow(label: "Insertion loss", value: String(format: "%.2f dB", report.insertionLoss),
                             color: Theme.accent)
                    ValueRow(label: "Centre frequency", value: Units.frequency(report.centerFrequency))
                    ValueRow(label: "−3 dB band",
                             value: "\(Units.frequencyShort(report.lowerCutoff)) – \(Units.frequencyShort(report.upperCutoff))")
                    ValueRow(label: "−3 dB bandwidth", value: Units.frequency(report.bandwidth3dB))
                    if report.bandwidth6dB > 0 {
                        ValueRow(label: "−6 dB bandwidth", value: Units.frequency(report.bandwidth6dB))
                    }
                    ValueRow(label: "Loaded Q", value: Units.fixed(report.q, 2))
                    ValueRow(label: "Passband ripple", value: String(format: "%.2f dB", report.passbandRipple))
                    if report.shapeFactor > 0 {
                        ValueRow(label: "Shape factor (60/3 dB)", value: Units.fixed(report.shapeFactor, 2))
                    }
                    ValueRow(label: "Stopband rejection", value: String(format: "%.1f dB", report.stopbandRejection))

                    Divider()
                    if let gain = peakGain {
                        ValueRow(label: gain.value > 0 ? "Peak gain" : "Peak loss",
                                 value: String(format: "%.2f dB", abs(gain.value)),
                                 color: gain.value > 0 ? Theme.statusGood : .primary)
                        ValueRow(label: "at", value: Units.frequency(gain.frequency))
                    }
                    if let flatness = passbandFlatness(report) {
                        ValueRow(label: "Flatness in band", value: String(format: "±%.2f dB", flatness / 2))
                    }
                }
            }
        }
    }

    private var peakGain: (value: Double, frequency: Double)? {
        let frame = model.displayFrame
        guard !frame.isEmpty else { return nil }
        let db = frame.s21.map { RF.dB($0.magnitude) }
        guard let index = TraceAnalysis.indexOfMaximum(db) else { return nil }
        return (db[index], frame.frequencies[index])
    }

    private func passbandFlatness(_ report: FilterAnalysis.Report) -> Double? {
        guard report.bandwidth3dB > 0 else { return nil }
        return report.passbandRipple
    }
}

/// Live view of the instrument's own screen.
struct DeviceScreenTool: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        PanelSection(title: "Instrument screen", systemImage: "display") {
            VStack(alignment: .leading, spacing: 8) {
                if let image = model.lastScreenCapture {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.05))
                        .frame(height: 120)
                        .overlay(
                            Text("No capture yet")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        )
                }
                HStack(spacing: 6) {
                    PillButton(title: "Capture", systemImage: "camera") { model.captureDeviceScreen() }
                        .disabled(!model.session.supportsScreenCapture)
                    PillButton(title: "Save PNG", systemImage: "square.and.arrow.down") {
                        model.saveDeviceScreenshot()
                    }
                    .disabled(model.lastScreenCapture == nil)
                }
                if !model.session.supportsScreenCapture {
                    Text("Screen capture needs a device with the text shell (NanoVNA, -H, -H4, -F and F V2). The binary V2 protocol has no capture command.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
