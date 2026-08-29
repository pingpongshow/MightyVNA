import SwiftUI
import VNACore

struct AppCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session") { model.newSession() }
                .keyboardShortcut("n")
            Button("Open Session…") { model.openSession() }
                .keyboardShortcut("o")
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save Session") { model.saveSession() }
                .keyboardShortcut("s")
            Button("Save Session As…") { model.saveSessionAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button("Import Touchstone…") { model.importTouchstone() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Menu("Export") {
                Button("Touchstone (.s1p)…") { model.exportTouchstone(ports: 1) }
                Button("Touchstone (.s2p)…") { model.exportTouchstone(ports: 2) }
                Button("CSV…") { model.exportCSV() }
                Button("Plot image (PNG)…") { model.exportPlotImage() }
                Divider()
                Button("Instrument screenshot…") { model.saveDeviceScreenshot() }
            }
        }

        CommandMenu("Device") {
            Button("Connect") { model.connect() }
                .keyboardShortcut("k", modifiers: [.command])
                .disabled(model.connection.isConnected)
            Button("Disconnect") { model.disconnect() }
                .disabled(!model.connection.isConnected)
            Button("Use NanoVNA Simulator") { model.connectSimulator() }
            Button("Use LibreVNA Simulator (two-port)") { model.connectLibreVNASimulator() }
            Divider()
            Button("Rescan Ports") { model.refreshPorts() }
            Button("Capture Instrument Screen") { model.captureDeviceScreen() }
            Button("Read Battery") { model.refreshBattery() }
        }

        CommandMenu("Sweep") {
            Button(model.isSweeping ? "Stop" : "Run") { model.toggleSweeping() }
                .keyboardShortcut(.space, modifiers: [])
            Button("Single Sweep") { model.singleSweep() }
                .keyboardShortcut("r", modifiers: [.command])
            Divider()
            Toggle("Continuous", isOn: Binding(get: { model.continuousSweep },
                                               set: { model.continuousSweep = $0 }))
            Button("Reset Averaging") { model.resetAveraging() }
        }

        CommandMenu("Calibration") {
            ForEach(CalStep.portOneStandards) { step in
                Button("Measure \(step.displayName)") { model.measureCalibrationStep(step) }
            }
            if model.isFullTwoPort {
                Divider()
                ForEach(CalStep.portTwoStandards) { step in
                    Button("Measure \(step.displayName)") { model.measureCalibrationStep(step) }
                }
            }
            Divider()
            Button("Measure Isolation") { model.measureCalibrationStep(.isolation) }
            Button("Measure Through") { model.measureCalibrationStep(.thru) }
            Divider()
            Toggle("Apply Calibration", isOn: Binding(
                get: { model.workspace.applyHostCalibration },
                set: { model.workspace.applyHostCalibration = $0; model.reprocessCurrentFrame() }
            ))
            Button("Clear Calibration") { model.clearCalibration() }
            Divider()
            Button("Save Calibration…") { model.saveCalibration() }
            Button("Load Calibration…") { model.loadCalibration() }
        }

        CommandMenu("Traces") {
            Button("Auto Scale All") { model.autoScaleAll() }
                .keyboardShortcut("=", modifiers: [.command])
            Button("Store Memory Trace") { model.storeMemory() }
                .keyboardShortcut("m", modifiers: [.command])
            Divider()
            Menu("Layout") {
                ForEach(ChartLayout.allCases) { layout in
                    Button(layout.displayName) { model.setLayout(layout) }
                }
            }
            Divider()
            Button("Add Marker") { model.addMarker() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .help) {
            Button("MightyVNA Help") {
                if let url = URL(string: "https://github.com/") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
