import SwiftUI
import VNACore

struct MemoryPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        PanelSection(title: "Memory & data", systemImage: "internaldrive") {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    PillButton(title: "Store sweep", systemImage: "square.and.arrow.down.on.square") {
                        model.storeMemory()
                    }
                    PillButton(title: "Import", systemImage: "square.and.arrow.up") {
                        model.importTouchstone()
                    }
                }

                if model.memories.isEmpty {
                    Text("Stored sweeps appear here. Use them as reference traces, or as the divisor in a normalised measurement.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(model.memories) { memory in
                        HStack(spacing: 6) {
                            Image(systemName: "waveform").font(.system(size: 10)).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(memory.label)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                Text("\(Units.frequencyShort(memory.startFrequency)) – \(Units.frequencyShort(memory.stopFrequency)) · \(memory.count) pts")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 0)
                            Button {
                                model.deleteMemory(memory.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Divider()

                HStack(spacing: 6) {
                    PillButton(title: "s1p", systemImage: "arrow.down.doc") { model.exportTouchstone(ports: 1) }
                    PillButton(title: "s2p", systemImage: "arrow.down.doc") { model.exportTouchstone(ports: 2) }
                    PillButton(title: "CSV", systemImage: "tablecells") { model.exportCSV() }
                }
                Text("s2p files carry the measured S11 and S21. This class of instrument does not measure the reverse direction, so S12 is written as a copy of S21 and S22 is zero.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
