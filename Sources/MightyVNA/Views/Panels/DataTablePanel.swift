import SwiftUI
import VNACore

/// Tabular view of every measured point, with copy support.
struct DataTablePanel: View {
    @EnvironmentObject var model: AppModel
    @State private var showAll = false

    private var rows: [Row] {
        let frame = model.displayFrame
        guard !frame.isEmpty else { return [] }
        let stride = showAll ? 1 : max(1, frame.count / 60)
        return Swift.stride(from: 0, to: frame.count, by: stride).map { i in
            Row(index: i, frame: frame)
        }
    }

    struct Row: Identifiable {
        var id: Int { index }
        var index: Int
        var frequency: Double
        var s11dB: Double
        var swr: Double
        var z: Complex
        var s21dB: Double
        var s21phase: Double

        init(index: Int, frame: SweepFrame) {
            self.index = index
            frequency = frame.frequencies[index]
            let a = frame.s11[index]
            let b = frame.s21[index]
            s11dB = RF.dB(a.magnitude)
            swr = RF.swr(a)
            z = RF.impedance(a, z0: frame.z0)
            s21dB = RF.dB(b.magnitude)
            s21phase = b.phase * 180 / .pi
        }
    }

    var body: some View {
        PanelSection(title: "Data table", systemImage: "tablecells") {
            VStack(alignment: .leading, spacing: 6) {
                if rows.isEmpty {
                    Text("Run a sweep to see the measured values.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        Toggle("Every point", isOn: $showAll)
                            .toggleStyle(.checkbox).font(.system(size: 11))
                        Spacer()
                        PillButton(title: "Copy", systemImage: "doc.on.doc") { copyToPasteboard() }
                    }

                    HStack(spacing: 0) {
                        header("Freq", width: 78)
                        header("S11 dB", width: 54)
                        header("SWR", width: 46)
                        header("R", width: 50)
                        header("X", width: 50)
                        header("S21 dB", width: 54)
                    }
                    .padding(.bottom, 2)

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { row in
                                HStack(spacing: 0) {
                                    cell(Units.frequencyShort(row.frequency), width: 78)
                                    cell(Units.fixed(row.s11dB, 2), width: 54)
                                    cell(Units.fixed(row.swr, 2), width: 46,
                                         color: row.swr < 2 ? Theme.statusGood : .primary)
                                    cell(Units.fixed(row.z.re, 1), width: 50)
                                    cell(Units.fixed(row.z.im, 1), width: 50)
                                    cell(Units.fixed(row.s21dB, 2), width: 54)
                                }
                                .padding(.vertical, 1)
                                .background(row.index % 2 == 0 ? Color.clear : Color.primary.opacity(0.03))
                            }
                        }
                    }
                    .frame(maxHeight: 320)

                    Text("\(model.displayFrame.count) points · showing \(rows.count)")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func header(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .trailing)
    }

    private func cell(_ text: String, width: CGFloat, color: Color = .primary) -> some View {
        Text(text)
            .font(Theme.monospaceSmall)
            .foregroundStyle(color)
            .frame(width: width, alignment: .trailing)
    }

    private func copyToPasteboard() {
        let text = Touchstone.csv(from: model.displayFrame)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.statusMessage = "Copied \(model.displayFrame.count) points to the clipboard"
    }
}
