import SwiftUI
import VNACore

/// Arranges the plot panes according to the chosen layout.
struct PlotGridView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let panes = Array(model.workspace.panes.prefix(model.workspace.layout.paneCount))
        Group {
            switch model.workspace.layout {
            case .single:
                grid(panes, columns: 1)
            case .twoRows:
                grid(panes, columns: 1)
            case .twoColumns:
                grid(panes, columns: 2)
            case .grid2x2:
                grid(panes, columns: 2)
            case .grid2x3:
                grid(panes, columns: 3)
            }
        }
        .padding(8)
        .background(Color(nsColor: .underPageBackgroundColor))
        .overlay {
            if model.displayFrame.isEmpty { emptyState }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("No measurement yet")
                .font(.title3.weight(.medium))
            Text("Connect a NanoVNA or LibreVNA over USB and press Run, or start one of the built-in simulators to explore every feature without hardware.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack(spacing: 10) {
                Button("Connect") { model.connect() }
                    .disabled(model.selectedDevice == nil)
                Button("NanoVNA Simulator") { model.connectSimulator() }
                Button("LibreVNA Simulator") { model.connectLibreVNASimulator() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
        )
        .allowsHitTesting(true)
    }

    @ViewBuilder
    private func grid(_ panes: [PlotPane], columns: Int) -> some View {
        let rows = Int(ceil(Double(panes.count) / Double(max(1, columns))))
        VStack(spacing: 8) {
            ForEach(0..<max(rows, 1), id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(0..<columns, id: \.self) { column in
                        let index = row * columns + column
                        if index < panes.count, let binding = model.paneBinding(panes[index].id) {
                            PlotPaneView(pane: binding)
                        } else if index < panes.count {
                            Color.clear
                        } else {
                            Color.clear
                        }
                    }
                }
            }
        }
    }
}
