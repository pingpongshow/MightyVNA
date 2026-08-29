import SwiftUI
import VNACore

struct CalibrationPanel: View {
    @EnvironmentObject var model: AppModel
    @State private var showingKitEditor = false
    @State private var showingDeviceCal = false

    var body: some View {
        PanelSection(title: "Calibration", systemImage: "checkmark.seal",
                     subtitle: "Host-side SOLT. Measurements are corrected on the Mac, so the instrument's own calibration is left untouched.") {
            VStack(alignment: .leading, spacing: 8) {

                modeBadge

                Text("Port 1")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(CalStep.portOneStandards) { step in
                    calStepRow(step)
                }

                if model.isFullTwoPort {
                    Text("Port 2 — for a full two-port calibration")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    ForEach(CalStep.portTwoStandards) { step in
                        calStepRow(step)
                    }
                }

                Text("Both ports")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                calStepRow(.isolation)
                calStepRow(.thru)

                Divider()

                Toggle("Apply calibration to live data", isOn: Binding(
                    get: { model.workspace.applyHostCalibration },
                    set: { model.workspace.applyHostCalibration = $0; model.reprocessCurrentFrame() }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .disabled(!model.calibration.isSolved)

                Picker("Cal kit", selection: Binding(
                    get: { model.calibration.kit.id },
                    set: { id in
                        if let kit = model.calKits.first(where: { $0.id == id }) { model.setCalKit(kit) }
                    }
                )) {
                    ForEach(model.calKits) { kit in
                        Text(kit.name).tag(kit.id)
                    }
                }
                .font(.system(size: 11))

                if model.calibration.mode != .fullTwoPort {
                Picker("S21 correction", selection: Binding(
                    get: { model.calibration.transmissionCorrection },
                    set: { model.calibration.transmissionCorrection = $0; model.calibration.solve(); model.reprocessCurrentFrame() }
                )) {
                    ForEach(TransmissionCorrection.allCases) { Text($0.displayName).tag($0) }
                }
                .font(.system(size: 11))
                .help(model.calibration.transmissionCorrection.explanation)
                }

                if model.calibration.isSolved {
                    VStack(alignment: .leading, spacing: 2) {
                        ValueRow(label: "Calibrated range", value: model.calibration.frequencyRangeDescription)
                        if let residual = model.calibration.residualDirectivityDB {
                            ValueRow(label: "Residual directivity",
                                     value: String(format: "%.1f dB", residual),
                                     color: residual < -40 ? Theme.statusGood : Theme.statusWarn,
                                     help: "How well the load standard corrects back to its ideal value. More negative is better; below −40 dB is a good calibration.")
                        }
                        if !model.displayFrame.isEmpty && !model.calibration.covers(model.displayFrame) {
                            Text("The current sweep extends beyond the calibrated range. Values outside it are extrapolated from the edges.")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.statusWarn)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                HStack(spacing: 6) {
                    PillButton(title: "Edit kit", systemImage: "slider.horizontal.3") { showingKitEditor = true }
                    PillButton(title: "Save", systemImage: "square.and.arrow.down") { model.saveCalibration() }
                    PillButton(title: "Load", systemImage: "square.and.arrow.up") { model.loadCalibration() }
                }
                HStack(spacing: 6) {
                    PillButton(title: "Clear all", systemImage: "trash", tint: Theme.statusBad) {
                        model.clearCalibration()
                    }
                    if model.session.supportsTextCommands {
                        PillButton(title: "On-device cal…", systemImage: "gearshape") { showingDeviceCal = true }
                    }
                }

                if !model.calibrationProgress.message.isEmpty {
                    Text(model.calibrationProgress.message)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .sheet(isPresented: $showingKitEditor) {
            CalKitEditor(kits: $model.calKits, selection: model.calibration.kit.id) { kit in
                model.setCalKit(kit)
            }
        }
        .sheet(isPresented: $showingDeviceCal) {
            DeviceCalibrationSheet()
        }
    }

    /// What the calibration can currently correct, and why.
    private var modeBadge: some View {
        let mode = model.calibration.mode
        let colour: Color = {
            switch mode {
            case .none: return .secondary
            case .reflectionOnly: return Theme.statusWarn
            case .forwardResponse: return Theme.accent
            case .fullTwoPort: return Theme.statusGood
            }
        }()
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: mode == .fullTwoPort ? "checkmark.seal.fill" : "seal")
                    .font(.system(size: 10))
                Text(mode.displayName)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(colour)
            Text(mode.explanation)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(colour.opacity(0.10)))
    }

    private func calStepRow(_ step: CalStep) -> some View {
        let done = model.calibration.has(step)
        let running = model.calibrationProgress.currentStep == step
        return HStack(spacing: 7) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12))
                .foregroundStyle(done ? Theme.statusGood : Color.secondary)

            VStack(alignment: .leading, spacing: 0) {
                Text(step.displayName)
                    .font(.system(size: 11, weight: .medium))
                Text(subtitle(for: step))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            if running {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 16, height: 16)
            } else {
                Button {
                    model.measureCalibrationStep(step)
                } label: {
                    Text(done ? "Redo" : "Measure").font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.calibrationProgress.isRunning)
                if done {
                    Button {
                        model.clearCalibrationStep(step)
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .help(step.instructions)
    }

    private func subtitle(for step: CalStep) -> String {
        switch step {
        case .open, .short, .load: return "Required for S11"
        case .open2, .short2, .load2: return "Required for S22 and 12-term"
        case .isolation: return "Optional · improves dynamic range"
        case .thru: return "Required for transmission"
        }
    }
}

/// Editor for the coefficients of a calibration kit.
struct CalKitEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var kits: [CalKit]
    var selection: UUID
    var onApply: (CalKit) -> Void

    @State private var working: CalKit = .ideal
    @State private var editingKind: StandardKind = .open

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Calibration kit").font(.title3.bold())
                Spacer()
                Picker("", selection: Binding(
                    get: { working.id },
                    set: { id in if let k = kits.first(where: { $0.id == id }) { working = k } }
                )) {
                    ForEach(kits) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .frame(width: 220)
            }

            TextField("Kit name", text: $working.name)
                .textFieldStyle(.roundedBorder)

            Picker("", selection: $editingKind) {
                ForEach(StandardKind.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            standardEditor

            Text(working.notes)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Offset delay is the one-way electrical length of the standard. Open capacitance and short inductance are polynomials in frequency; the values on your kit's data sheet are usually given in fF and pH with 10⁻²⁷, 10⁻³⁶, 10⁻⁴⁵ scaling on the higher terms.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Duplicate as new kit") {
                    var copy = working
                    copy.id = UUID()
                    copy.name = working.name + " (copy)"
                    kits.append(copy)
                    working = copy
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply") {
                    if let index = kits.firstIndex(where: { $0.id == working.id }) {
                        kits[index] = working
                    } else {
                        kits.append(working)
                    }
                    onApply(working)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 480)
        .onAppear {
            working = kits.first { $0.id == selection } ?? .ideal
        }
    }

    @ViewBuilder
    private var standardEditor: some View {
        let binding = standardBinding(editingKind)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                NumericField(title: "Delay", value: Binding(
                    get: { binding.wrappedValue.offsetDelay * 1e12 },
                    set: { binding.wrappedValue.offsetDelay = $0 * 1e-12 }
                ), unit: "ps", format: "%.4f", width: 44)
                NumericField(title: "Loss", value: binding.offsetLoss, unit: "Ω/s", format: "%.4g", width: 34)
                NumericField(title: "Z₀", value: binding.offsetZ0, unit: "Ω", format: "%.2f", width: 24)
            }
            switch editingKind {
            case .open:
                HStack(spacing: 10) {
                    NumericField(title: "C0", value: Binding(
                        get: { binding.wrappedValue.c0 * 1e15 },
                        set: { binding.wrappedValue.c0 = $0 * 1e-15 }), unit: "fF", format: "%.4f", width: 24)
                    NumericField(title: "C1", value: Binding(
                        get: { binding.wrappedValue.c1 * 1e27 },
                        set: { binding.wrappedValue.c1 = $0 * 1e-27 }), unit: "×10⁻²⁷", format: "%.4f", width: 24)
                }
                HStack(spacing: 10) {
                    NumericField(title: "C2", value: Binding(
                        get: { binding.wrappedValue.c2 * 1e36 },
                        set: { binding.wrappedValue.c2 = $0 * 1e-36 }), unit: "×10⁻³⁶", format: "%.4f", width: 24)
                    NumericField(title: "C3", value: Binding(
                        get: { binding.wrappedValue.c3 * 1e45 },
                        set: { binding.wrappedValue.c3 = $0 * 1e-45 }), unit: "×10⁻⁴⁵", format: "%.4f", width: 24)
                }
            case .short:
                HStack(spacing: 10) {
                    NumericField(title: "L0", value: Binding(
                        get: { binding.wrappedValue.l0 * 1e12 },
                        set: { binding.wrappedValue.l0 = $0 * 1e-12 }), unit: "pH", format: "%.4f", width: 24)
                    NumericField(title: "L1", value: Binding(
                        get: { binding.wrappedValue.l1 * 1e24 },
                        set: { binding.wrappedValue.l1 = $0 * 1e-24 }), unit: "×10⁻²⁴", format: "%.4f", width: 24)
                }
                HStack(spacing: 10) {
                    NumericField(title: "L2", value: Binding(
                        get: { binding.wrappedValue.l2 * 1e33 },
                        set: { binding.wrappedValue.l2 = $0 * 1e-33 }), unit: "×10⁻³³", format: "%.4f", width: 24)
                    NumericField(title: "L3", value: Binding(
                        get: { binding.wrappedValue.l3 * 1e42 },
                        set: { binding.wrappedValue.l3 = $0 * 1e-42 }), unit: "×10⁻⁴²", format: "%.4f", width: 24)
                }
            case .load:
                HStack(spacing: 10) {
                    NumericField(title: "R", value: binding.loadResistance, unit: "Ω", format: "%.4f", width: 24)
                    NumericField(title: "L", value: Binding(
                        get: { binding.wrappedValue.loadInductance * 1e12 },
                        set: { binding.wrappedValue.loadInductance = $0 * 1e-12 }), unit: "pH", format: "%.3f", width: 24)
                }
            case .thru:
                Text("The through standard's delay and loss are removed from the S21 normalisation.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func standardBinding(_ kind: StandardKind) -> Binding<CalStandard> {
        Binding(
            get: { working.standard(kind) },
            set: { working.setStandard($0) }
        )
    }
}

/// Passthrough for the instrument's own calibration commands.
struct DeviceCalibrationSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var output = ""
    @State private var busy = false

    private let steps: [(String, String)] = [
        ("reset", "Erase the current on-device calibration"),
        ("open", "Measure OPEN on CH0"),
        ("short", "Measure SHORT on CH0"),
        ("load", "Measure LOAD on CH0"),
        ("isoln", "Measure isolation (loads on both ports)"),
        ("thru", "Measure THROUGH (CH0 to CH1)"),
        ("done", "Compute and apply"),
        ("on", "Enable correction"),
        ("off", "Disable correction")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("On-device calibration").font(.title3.bold())
            Text("These commands run the instrument's own calibration, exactly as if you used its menus. It is stored in the analyser and is independent of the host calibration MightyVNA applies on the Mac.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130))], spacing: 6) {
                ForEach(steps, id: \.0) { step in
                    Button {
                        run("cal \(step.0)")
                    } label: {
                        Text(step.0).frame(maxWidth: .infinity)
                    }
                    .controlSize(.small)
                    .help(step.1)
                    .disabled(busy)
                }
            }

            HStack {
                Text("Memory slot").font(.system(size: 11))
                ForEach(0..<5) { slot in
                    Button("\(slot)") { save(slot) }.controlSize(.small)
                }
                Text("recall").font(.system(size: 11)).padding(.leading, 8)
                ForEach(0..<5) { slot in
                    Button("\(slot)") { recall(slot) }.controlSize(.small)
                }
            }

            ScrollView {
                Text(output.isEmpty ? "Command output appears here." : output)
                    .font(Theme.monospaceSmall)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 120)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))

            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 520)
    }

    private func run(_ command: String) {
        busy = true
        Task {
            do {
                let subcommand = command.replacingOccurrences(of: "cal ", with: "")
                let result = try await model.session.deviceCalibration(subcommand)
                output += "> \(command)\n\(result)\n"
            } catch {
                output += "> \(command)\nError: \(error.localizedDescription)\n"
            }
            busy = false
        }
    }

    private func save(_ slot: Int) {
        Task {
            do {
                try await model.session.saveDeviceSlot(slot)
                output += "> save \(slot)\nOK\n"
            } catch { output += "Error: \(error.localizedDescription)\n" }
        }
    }

    private func recall(_ slot: Int) {
        Task {
            do {
                try await model.session.recallDeviceSlot(slot)
                output += "> recall \(slot)\nOK\n"
            } catch { output += "Error: \(error.localizedDescription)\n" }
        }
    }
}
