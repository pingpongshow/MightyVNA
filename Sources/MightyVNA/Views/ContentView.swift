import SwiftUI
import VNACore

enum InspectorTab: String, CaseIterable, Identifiable {
    case calibration = "Calibration"
    case analysis = "Analysis"
    case timeDomain = "Time domain"
    case data = "Data"
    case limits = "Limits"
    case console = "Console"

    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .calibration: return "checkmark.seal"
        case .analysis: return "function"
        case .timeDomain: return "waveform.path"
        case .data: return "internaldrive"
        case .limits: return "checklist"
        case .console: return "terminal"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var inspectorVisible = true
    @State private var inspectorTab: InspectorTab = .calibration
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        } detail: {
            VStack(spacing: 0) {
                PlotGridView()
                Divider()
                StatusBar()
            }
            .inspector(isPresented: $inspectorVisible) {
                inspector
                    .inspectorColumnWidth(min: 280, ideal: 330, max: 460)
            }
        }
        .toolbar { toolbarContent }
        .alert("MightyVNA", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
        .frame(minWidth: 1100, minHeight: 700)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(spacing: 10) {
                DevicePanel()
                if model.isLibreVNA { LibreVNAPanel() }
                SweepPanel()
                DisplayPanel()
                TracePanel()
                MarkerPanel()
            }
            .padding(10)
        }
        .background(Theme.panelBackground)
    }

    // MARK: - Inspector

    private var inspector: some View {
        VStack(spacing: 0) {
            Picker("", selection: $inspectorTab) {
                ForEach(InspectorTab.allCases) { tab in
                    Image(systemName: tab.systemImage).tag(tab)
                        .help(tab.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            Divider()

            Group {
                switch inspectorTab {
                case .calibration:
                    scrolling { CalibrationPanel() }
                case .analysis:
                    scrolling {
                        AntennaTool()
                        FilterTool()
                        MatchingTool()
                        CableTool()
                    }
                case .timeDomain:
                    scrolling { TimeDomainPanel() }
                case .data:
                    scrolling {
                        MemoryPanel()
                        DataTablePanel()
                        DeviceScreenTool()
                    }
                case .limits:
                    scrolling { LimitsPanel() }
                case .console:
                    ConsolePanel()
                }
            }
        }
        .background(Theme.panelBackground)
    }

    @ViewBuilder
    private func scrolling<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(spacing: 10) {
                content()
            }
            .padding(10)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                model.toggleSweeping()
            } label: {
                Label(model.isSweeping ? "Stop" : "Run",
                      systemImage: model.isSweeping ? "stop.fill" : "play.fill")
            }
            .help(model.isSweeping ? "Stop sweeping (Space)" : "Start sweeping (Space)")

            Button {
                model.singleSweep()
            } label: {
                Label("Single", systemImage: "playpause")
            }
            .help("Run one sweep")
        }

        ToolbarItemGroup {
            Menu {
                ForEach(ChartLayout.allCases) { layout in
                    Button {
                        model.setLayout(layout)
                    } label: {
                        Label(layout.displayName, systemImage: layout.systemImage)
                    }
                }
            } label: {
                Label("Layout", systemImage: model.workspace.layout.systemImage)
            }
            .help("Plot layout")

            Button {
                model.autoScaleAll()
            } label: {
                Label("Auto scale", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .help("Auto scale every trace")

            Button {
                model.storeMemory()
            } label: {
                Label("Store", systemImage: "square.and.arrow.down.on.square")
            }
            .help("Store the current sweep as a memory trace")

            Button {
                inspectorVisible.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
        }
    }
}
