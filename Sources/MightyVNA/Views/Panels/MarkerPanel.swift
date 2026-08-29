import SwiftUI
import VNACore

struct MarkerPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        PanelSection(title: "Markers", systemImage: "mappin.and.ellipse") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach($model.workspace.markers) { $marker in
                    markerRow($marker)
                }

                HStack(spacing: 6) {
                    PillButton(title: "Add", systemImage: "plus") { model.addMarker() }
                        .disabled(model.workspace.markers.count >= 8)
                    Menu {
                        Button("All markers to trace maximum") { setAllTracking(.maximum) }
                        Button("All markers to trace minimum") { setAllTracking(.minimum) }
                        Button("Spread across the sweep") { spreadMarkers() }
                        Divider()
                        Button("Disable all") {
                            for i in model.workspace.markers.indices { model.workspace.markers[i].enabled = false }
                        }
                    } label: {
                        Label("Arrange", systemImage: "wand.and.stars").font(.system(size: 11))
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 80)
                }

                if let index = model.activeMarkerIndex() {
                    Divider()
                    MarkerDetail(marker: $model.workspace.markers[index])
                }
            }
        }
    }

    private func markerRow(_ marker: Binding<Marker>) -> some View {
        HStack(spacing: 6) {
            Toggle("", isOn: marker.enabled)
                .toggleStyle(.checkbox)
                .labelsHidden()

            Circle()
                .fill(Theme.markerColor(marker.wrappedValue.colorIndex))
                .frame(width: 8, height: 8)

            Text(marker.wrappedValue.label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .frame(width: 22, alignment: .leading)

            Text(Units.frequency(marker.wrappedValue.frequency))
                .font(Theme.monospaceSmall)
                .foregroundStyle(marker.wrappedValue.enabled ? .primary : .secondary)

            Spacer(minLength: 0)

            if marker.wrappedValue.tracking != .none {
                Image(systemName: "scope").font(.system(size: 9)).foregroundStyle(Theme.accent)
            }

            if model.workspace.markers.count > 1 {
                Button {
                    model.removeMarker(marker.wrappedValue.id)
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(model.activeMarkerID == marker.wrappedValue.id ? Theme.accent.opacity(0.15) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.activeMarkerID = marker.wrappedValue.id }
    }

    private func setAllTracking(_ tracking: MarkerTracking) {
        for i in model.workspace.markers.indices {
            model.workspace.markers[i].tracking = tracking
            model.workspace.markers[i].enabled = true
        }
        model.updateMarkerTracking()
    }

    private func spreadMarkers() {
        let enabled = model.workspace.markers.indices.filter { model.workspace.markers[$0].enabled }
        guard !enabled.isEmpty else { return }
        let sweep = model.workspace.sweep
        for (position, index) in enabled.enumerated() {
            let t = enabled.count > 1 ? Double(position) / Double(enabled.count - 1) : 0.5
            model.workspace.markers[index].frequency = sweep.start + sweep.span * t
            model.workspace.markers[index].tracking = .none
        }
    }
}

/// Full readout and controls for the selected marker.
struct MarkerDetail: View {
    @EnvironmentObject var model: AppModel
    @Binding var marker: Marker

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FrequencyField(title: "Freq", value: $marker.frequency)

            Picker("Tracking", selection: $marker.tracking) {
                ForEach(MarkerTracking.allCases) { Text($0.displayName).tag($0) }
            }
            .font(.system(size: 11))
            .onChange(of: marker.tracking) { _, _ in model.updateMarkerTracking() }

            Picker("Bound to", selection: Binding(
                get: { marker.boundTraceID ?? model.workspace.traces.first?.id ?? UUID() },
                set: { marker.boundTraceID = $0 }
            )) {
                ForEach(model.workspace.traces) { trace in
                    Text(trace.displayName).tag(trace.id)
                }
            }
            .font(.system(size: 11))

            Picker("Delta from", selection: Binding(
                get: { marker.deltaReferenceID ?? UUID() },
                set: { id in marker.deltaReferenceID = model.workspace.markers.contains { $0.id == id } ? id : nil }
            )) {
                Text("None").tag(UUID())
                ForEach(model.workspace.markers.filter { $0.id != marker.id }) { other in
                    Text(other.label).tag(other.id)
                }
            }
            .font(.system(size: 11))

            Divider()
            readout
        }
    }

    private var readout: some View {
        let frame = model.displayFrame
        let index = frame.isEmpty ? 0 : frame.nearestIndex(to: marker.frequency)
        let deltaMarker = marker.deltaReferenceID.flatMap { id in model.workspace.markers.first { $0.id == id } }
        let deltaIndex = deltaMarker.map { frame.nearestIndex(to: $0.frequency) }

        return VStack(alignment: .leading, spacing: 2) {
            if frame.isEmpty {
                Text("No sweep data yet.").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                let s11 = frame.s11[index]
                let s21 = frame.s21[index]
                let z = RF.impedance(s11, z0: frame.z0)

                ValueRow(label: "Frequency", value: Units.frequency(frame.frequencies[index]))
                if let deltaIndex, let deltaMarker {
                    ValueRow(label: "Δf from \(deltaMarker.label)",
                             value: Units.frequency(frame.frequencies[index] - frame.frequencies[deltaIndex]),
                             color: Theme.accent)
                }
                Divider().padding(.vertical, 2)
                ValueRow(label: "S11", value: String(format: "%.2f dB  ∠%.1f°", RF.dB(s11.magnitude), s11.phase * 180 / .pi))
                ValueRow(label: "SWR", value: Units.fixed(RF.swr(s11), 3),
                         color: RF.swr(s11) < 2 ? Theme.statusGood : (RF.swr(s11) < 3 ? Theme.statusWarn : Theme.statusBad))
                ValueRow(label: "Return loss", value: String(format: "%.2f dB", RF.returnLoss(s11)))
                ValueRow(label: "Z", value: String(format: "%.2f %@ j%.2f Ω", z.re, z.im < 0 ? "−" : "+", abs(z.im)))
                ValueRow(label: "|Z|", value: Units.ohms(z.magnitude))
                if z.im > 0 {
                    ValueRow(label: "Equivalent L",
                             value: Units.inductance(RF.seriesInductance(s11, z0: frame.z0, frequency: frame.frequencies[index])))
                } else if z.im < 0 {
                    ValueRow(label: "Equivalent C",
                             value: Units.capacitance(RF.seriesCapacitance(s11, z0: frame.z0, frequency: frame.frequencies[index])))
                }
                ValueRow(label: "Q", value: Units.fixed(RF.qFactor(s11, z0: frame.z0), 2))
                Divider().padding(.vertical, 2)
                ValueRow(label: "S21", value: String(format: "%.2f dB  ∠%.1f°", RF.dB(s21.magnitude), s21.phase * 180 / .pi))
                if frame.isFullTwoPort {
                    let s12 = frame.s12[index]
                    let s22 = frame.s22[index]
                    let z2 = RF.impedance(s22, z0: frame.z0)
                    ValueRow(label: "S12", value: String(format: "%.2f dB  ∠%.1f°", RF.dB(s12.magnitude), s12.phase * 180 / .pi))
                    ValueRow(label: "S22", value: String(format: "%.2f dB  ∠%.1f°", RF.dB(s22.magnitude), s22.phase * 180 / .pi))
                    ValueRow(label: "SWR (port 2)", value: Units.fixed(RF.swr(s22), 3))
                    ValueRow(label: "Z (port 2)",
                             value: String(format: "%.2f %@ j%.2f Ω", z2.re, z2.im < 0 ? "−" : "+", abs(z2.im)))
                }
                if let deltaIndex {
                    let d11 = RF.dB(frame.s11[index].magnitude) - RF.dB(frame.s11[deltaIndex].magnitude)
                    let d21 = RF.dB(frame.s21[index].magnitude) - RF.dB(frame.s21[deltaIndex].magnitude)
                    ValueRow(label: "ΔS11", value: String(format: "%+.2f dB", d11), color: Theme.accent)
                    ValueRow(label: "ΔS21", value: String(format: "%+.2f dB", d21), color: Theme.accent)
                }
            }
        }
    }
}
