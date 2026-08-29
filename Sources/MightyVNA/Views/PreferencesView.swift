import SwiftUI
import VNACore

struct PreferencesView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("autoConnectOnLaunch") private var autoConnect = false
    @AppStorage("preferredZ0") private var preferredZ0 = 50.0
    @AppStorage("consoleLogging") private var consoleLogging = true

    var body: some View {
        TabView {
            Form {
                Toggle("Log serial traffic to the console", isOn: $consoleLogging)
                    .onChange(of: consoleLogging) { _, value in model.logTraffic = value }
                Toggle("Connect to the first analyser found at launch", isOn: $autoConnect)
                Picker("Default reference impedance", selection: $preferredZ0) {
                    Text("50 Ω").tag(50.0)
                    Text("75 Ω").tag(75.0)
                }
            }
            .padding(20)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Text("MightyVNA speaks two protocols:")
                    .font(.headline)
                Text("• The ASCII text shell used by the original NanoVNA, NanoVNA-H, -H4 and the SYSJOINT NanoVNA-F family including the F V2.\n• The NanoVNA V2 binary register protocol used by the S-A-A-2, V2 Plus4, LiteVNA and SV series.")
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                ForEach(DeviceCatalog.all) { device in
                    HStack {
                        Text(device.name).font(.system(size: 11, weight: .medium))
                        Spacer()
                        Text(device.frequencyRangeDescription).font(Theme.monospaceSmall).foregroundStyle(.secondary)
                        Text(device.wireProtocol == .asciiShell ? "ASCII" : "V2")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.1)))
                    }
                }
            }
            .padding(20)
            .tabItem { Label("Devices", systemImage: "cable.connector") }
        }
        .frame(width: 520, height: 420)
    }
}
