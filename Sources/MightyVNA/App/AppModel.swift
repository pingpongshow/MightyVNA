import SwiftUI
import Combine
import VNACore
import AppKit
import UniformTypeIdentifiers

enum ConnectionState: Equatable {
    case disconnected
    case connecting(String)
    case connected(String)
    case failed(String)

    var isConnected: Bool { if case .connected = self { return true }; return false }
    var isBusy: Bool { if case .connecting = self { return true }; return false }
}

/// Calibration workflow state machine.
struct CalibrationProgress {
    var isRunning = false
    var currentStep: CalStep?
    var message = ""
}

@MainActor
final class AppModel: ObservableObject {

    // MARK: - Device

    let session = DeviceSession()
    @Published var devices: [DiscoveredDevice] = []
    @Published var selectedDevice: DiscoveredDevice?
    @Published var connectionPreference: ConnectionPreference = .automatic
    @Published var connection: ConnectionState = .disconnected
    @Published var deviceInfo: DeviceInfo?
    @Published var batteryMillivolts: Int?
    /// Mirror of the LibreVNA's acquisition settings, pushed to the driver on change.
    @Published var libreSettings = DeviceSession.LibreVNASettings()

    // MARK: - Data

    @Published var workspace: Workspace = .makeDefault()
    @Published private(set) var rawFrame: SweepFrame = .empty
    @Published private(set) var displayFrame: SweepFrame = .empty
    @Published var memories: [SweepFrame] = []
    @Published var calibration = Calibration()
    @Published var calKits: [CalKit] = CalKit.builtIns
    @Published var calibrationProgress = CalibrationProgress()

    // MARK: - Acquisition

    @Published var isSweeping = false
    @Published var continuousSweep = true
    @Published var sweepProgress: Double = 1
    @Published var sweepsCompleted = 0
    @Published var lastSweepDuration: TimeInterval = 0
    @Published var averagingSamples = 0

    // MARK: - UI

    @Published var trafficLog: [TrafficLogEntry] = []
    @Published var logTraffic = true
    @Published var statusMessage = "Ready"
    @Published var alertMessage: String?
    @Published var selectedTraceID: UUID?
    @Published var activeMarkerID: UUID?
    @Published var lastScreenCapture: NSImage?
    @Published var documentURL: URL?
    @Published var hasUnsavedChanges = false

    private var accumulator = SweepAccumulator()
    private var sweepTask: Task<Void, Never>?
    private var portRefreshTimer: Timer?

    init() {
        session.trafficHandler = { [weak self] entry in
            Task { @MainActor in self?.append(entry) }
        }
        session.progressHandler = { [weak self] value in
            Task { @MainActor in self?.sweepProgress = value }
        }
        refreshPorts()
        selectedTraceID = workspace.traces.first?.id
        activeMarkerID = workspace.markers.first?.id
        startPortMonitoring()

        // `MightyVNA --simulator` starts against the synthetic device, which is handy
        // for demos and for working on the app with no hardware to hand.
        if CommandLine.arguments.contains("--librevna-simulator")
            || ProcessInfo.processInfo.environment["MIGHTYVNA_SIMULATOR"] == "librevna" {
            connectLibreVNASimulator()
        } else if CommandLine.arguments.contains("--simulator")
            || ProcessInfo.processInfo.environment["MIGHTYVNA_SIMULATOR"] == "1" {
            connectSimulator()
        }
    }

    // MARK: - Ports

    func refreshPorts() {
        let discovered = session.discoverDevices()
        devices = discovered
        if let current = selectedDevice, !discovered.contains(where: { $0.id == current.id }) {
            selectedDevice = discovered.first
        } else if selectedDevice == nil {
            selectedDevice = discovered.first
        }
    }

    private func startPortMonitoring() {
        portRefreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.connection.isConnected else { return }
                self.refreshPorts()
            }
        }
    }

    // MARK: - Connection

    func connect() {
        guard let device = selectedDevice else {
            alertMessage = "Select a device first. If the list is empty, check the USB cable and that the "
                         + "analyser is powered on. NanoVNA units appear as a serial port; a LibreVNA appears "
                         + "as a raw USB device."
            return
        }
        connection = .connecting(device.displayName)
        statusMessage = "Connecting to \(device.displayName)…"
        Task {
            do {
                let info = try await session.connect(to: device, preference: connectionPreference)
                deviceInfo = info
                connection = .connected(info.model.name)
                batteryMillivolts = info.batteryMillivolts
                statusMessage = "Connected to \(info.model.name) on \(info.portPath)"
                adoptDeviceLimits(info)
                configureTracesForConnectedDevice()
                refreshLibreSettings()
                hasUnsavedChanges = true
                if continuousSweep { startSweeping() }
            } catch {
                connection = .failed(error.localizedDescription)
                statusMessage = "Connection failed"
                alertMessage = "Could not connect to \(device.displayName).\n\n\(error.localizedDescription)"
            }
        }
    }

    func connectSimulator() {
        startSimulator(named: "NanoVNA simulator") { try await self.session.connectSimulator() }
    }

    /// The synthetic two-port instrument, for exercising S12/S22 and the 12-term calibration.
    func connectLibreVNASimulator() {
        startSimulator(named: "LibreVNA simulator") { try await self.session.connectLibreVNASimulator() }
    }

    private func startSimulator(named name: String, connect: @escaping () async throws -> DeviceInfo) {
        connection = .connecting(name)
        Task {
            do {
                let info = try await connect()
                deviceInfo = info
                connection = .connected(info.model.name)
                batteryMillivolts = info.batteryMillivolts
                statusMessage = "Running against the \(name)"
                adoptDeviceLimits(info)
                configureTracesForConnectedDevice()
                refreshLibreSettings()
                if continuousSweep { startSweeping() }
            } catch {
                connection = .failed(error.localizedDescription)
                alertMessage = error.localizedDescription
            }
        }
    }

    func disconnect() {
        stopSweeping()
        Task {
            await session.disconnect()
            connection = .disconnected
            deviceInfo = nil
            statusMessage = "Disconnected"
        }
    }

    private func adoptDeviceLimits(_ info: DeviceInfo) {
        var sweep = workspace.sweep
        sweep.start = max(sweep.start, info.model.minFrequency)
        sweep.stop = min(sweep.stop, info.model.maxFrequency)
        if sweep.stop <= sweep.start { sweep.stop = min(info.model.maxFrequency, sweep.start * 10 + 1e6) }
        if workspace.sweep.points == SweepConfiguration().points {
            sweep.points = info.model.defaultPoints
        }
        workspace.sweep = sweep
    }

    var isLibreVNA: Bool { deviceInfo?.model.wireProtocol == .libreVNA }

    /// Pull the driver's current acquisition settings into the published mirror.
    func refreshLibreSettings() {
        Task {
            if let settings = await session.libreVNASettings() { libreSettings = settings }
        }
    }

    /// Mutate the mirror and push the change down to the driver.
    func updateLibreVNASettings(_ mutate: (inout DeviceSession.LibreVNASettings) -> Void) {
        var settings = libreSettings
        mutate(&settings)
        libreSettings = settings
        Task {
            await session.applyLibreVNASettings(settings)
            if let confirmed = await session.libreVNASettings() { libreSettings = confirmed }
            // Reverse measurement changes what the traces can show.
            reprocessCurrentFrame()
        }
    }

    /// Channels the connected instrument can actually measure.
    var availableChannels: [Channel] {
        if displayFrame.isFullTwoPort { return Channel.fullTwoPort }
        if isLibreVNA && !libreSettings.measureReverse { return Channel.nanoVNASubset }
        if let model = deviceInfo?.model, model.isFullTwoPort { return Channel.fullTwoPort }
        return Channel.nanoVNASubset
    }

    var isFullTwoPort: Bool { availableChannels.count == 4 }

    /// On a two-port instrument, add S12/S22 panes the first time one connects.
    private func configureTracesForConnectedDevice() {
        guard isFullTwoPort else { return }
        guard !workspace.traces.contains(where: { $0.channel == .s22 || $0.channel == .s12 }) else { return }
        var reverse = Trace(channel: .s12, format: .logMag, colorIndex: workspace.traces.count)
        reverse.applyDefaultScale()
        reverse.scalePerDivision = 10
        reverse.referencePosition = 9
        var port2 = Trace(channel: .s22, format: .logMag, colorIndex: workspace.traces.count + 1)
        port2.applyDefaultScale()
        port2.scalePerDivision = 10
        port2.referencePosition = 9
        workspace.traces.append(contentsOf: [reverse, port2])
        // Put them alongside the existing transmission and reflection plots.
        if let transmissionPane = workspace.panes.lastIndex(where: { pane in
            pane.traceIDs.contains { workspace.trace(id: $0)?.channel == .s21 }
        }) {
            workspace.panes[transmissionPane].traceIDs.append(reverse.id)
        }
        if let reflectionPane = workspace.panes.firstIndex(where: { pane in
            pane.kind == .rectangular && pane.traceIDs.contains { workspace.trace(id: $0)?.channel == .s11 }
        }) {
            workspace.panes[reflectionPane].traceIDs.append(port2.id)
        }
    }

    // MARK: - Sweeping

    func startSweeping() {
        guard session.isConnected else {
            alertMessage = "Connect an analyser first, or choose Device ▸ Use Simulator to explore the app without hardware."
            return
        }
        guard sweepTask == nil else { return }
        isSweeping = true
        accumulator.mode = workspace.averagingMode
        accumulator.depth = workspace.averagingDepth

        sweepTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let config = await MainActor.run { self.workspace.sweep }
                let started = Date()
                do {
                    let frame = try await self.session.sweep(config)
                    await MainActor.run {
                        self.lastSweepDuration = Date().timeIntervalSince(started)
                        self.ingest(frame)
                    }
                } catch {
                    await MainActor.run {
                        self.statusMessage = "Sweep failed: \(error.localizedDescription)"
                        self.alertMessage = error.localizedDescription
                        self.stopSweeping()
                    }
                    return
                }
                let keepGoing = await MainActor.run { self.continuousSweep }
                if !keepGoing { break }
            }
            await MainActor.run {
                self.isSweeping = false
                self.sweepTask = nil
            }
        }
    }

    func stopSweeping() {
        sweepTask?.cancel()
        sweepTask = nil
        isSweeping = false
    }

    func singleSweep() {
        let wasContinuous = continuousSweep
        continuousSweep = false
        startSweeping()
        continuousSweep = wasContinuous
    }

    func toggleSweeping() {
        if isSweeping { stopSweeping() } else { startSweeping() }
    }

    /// Feed a freshly acquired frame through calibration and averaging.
    private func ingest(_ frame: SweepFrame) {
        var incoming = frame
        incoming.z0 = workspace.z0
        rawFrame = incoming

        var corrected = incoming
        if workspace.applyHostCalibration && calibration.isSolved {
            corrected = calibration.apply(to: incoming)
        }
        if accumulator.mode != workspace.averagingMode || accumulator.depth != workspace.averagingDepth {
            accumulator.mode = workspace.averagingMode
            accumulator.depth = workspace.averagingDepth
            accumulator.reset()
        }
        displayFrame = accumulator.process(corrected)
        averagingSamples = accumulator.samples
        sweepsCompleted += 1
        // Drivers can learn the real hardware point limit on the first sweep.
        if let live = session.currentInfo,
           live.model.maxHardwarePoints != deviceInfo?.model.maxHardwarePoints {
            deviceInfo = live
        }
        placeStrayMarkers()
        updateMarkerTracking()
        hasUnsavedChanges = true
    }

    /// Replace the current data directly, bypassing acquisition (import, session load).
    func setFrames(raw: SweepFrame, display: SweepFrame) {
        var r = raw; r.z0 = workspace.z0
        var d = display; d.z0 = workspace.z0
        rawFrame = r
        displayFrame = d
        accumulator.reset()
        averagingSamples = 0
        placeStrayMarkers()
        updateMarkerTracking()
    }

    /// Recompute the displayed frame when calibration or averaging settings change.
    func reprocessCurrentFrame() {
        guard !rawFrame.isEmpty else { return }
        accumulator.reset()
        ingest(rawFrame)
    }

    func resetAveraging() {
        accumulator.reset()
        averagingSamples = 0
    }

    // MARK: - Calibration

    /// Acquire one sweep and store it as the given calibration standard.
    func measureCalibrationStep(_ step: CalStep) {
        guard session.isConnected else {
            alertMessage = "Connect an analyser before calibrating."
            return
        }
        let wasSweeping = isSweeping
        stopSweeping()
        calibrationProgress = CalibrationProgress(isRunning: true, currentStep: step,
                                                  message: "Measuring \(step.displayName)…")
        Task {
            do {
                // Two sweeps: the first settles the hardware after any range change.
                _ = try? await session.sweep(workspace.sweep)
                let frame = try await session.sweep(workspace.sweep)
                var stamped = frame
                stamped.z0 = workspace.z0
                calibration.record(step: step, frame: stamped)
                calibrationProgress = CalibrationProgress(isRunning: false, currentStep: nil,
                                                          message: "\(step.displayName) captured")
                statusMessage = "Calibration: \(step.displayName) captured (\(calibration.summary))"
                reprocessCurrentFrame()
                hasUnsavedChanges = true
            } catch {
                calibrationProgress = CalibrationProgress(isRunning: false, currentStep: nil, message: "")
                alertMessage = "Calibration measurement failed: \(error.localizedDescription)"
            }
            if wasSweeping { startSweeping() }
        }
    }

    func clearCalibrationStep(_ step: CalStep) {
        calibration.clear(step: step)
        reprocessCurrentFrame()
    }

    func clearCalibration() {
        calibration.clearAll()
        reprocessCurrentFrame()
        statusMessage = "Calibration cleared"
    }

    func setCalKit(_ kit: CalKit) {
        calibration.kit = kit
        calibration.solve()
        reprocessCurrentFrame()
    }

    // MARK: - Memory traces

    func storeMemory() {
        guard !displayFrame.isEmpty else {
            alertMessage = "There is no sweep to store yet."
            return
        }
        var frame = displayFrame
        frame.id = UUID()
        frame.label = "Memory \(memories.count + 1) · \(Date().formatted(date: .omitted, time: .standard))"
        memories.append(frame)
        statusMessage = "Stored \(frame.label)"
        hasUnsavedChanges = true
    }

    func deleteMemory(_ id: UUID) {
        memories.removeAll { $0.id == id }
        workspace.traces.removeAll { $0.source.memoryID == id }
        for i in workspace.panes.indices {
            workspace.panes[i].traceIDs.removeAll { id in !workspace.traces.contains { $0.id == id } }
        }
    }

    var memoryLookup: [UUID: SweepFrame] {
        Dictionary(uniqueKeysWithValues: memories.map { ($0.id, $0) })
    }

    // MARK: - Traces

    func addTrace(channel: Channel = .s11, format: TraceFormat = .logMag, toPane paneID: UUID? = nil) {
        var trace = Trace(channel: channel, format: format, colorIndex: workspace.traces.count)
        trace.applyDefaultScale()
        workspace.traces.append(trace)
        if let paneID, let index = workspace.panes.firstIndex(where: { $0.id == paneID }) {
            workspace.panes[index].traceIDs.append(trace.id)
        } else if let index = workspace.panes.indices.first {
            workspace.panes[index].traceIDs.append(trace.id)
        }
        selectedTraceID = trace.id
        hasUnsavedChanges = true
    }

    func removeTrace(_ id: UUID) {
        workspace.traces.removeAll { $0.id == id }
        for i in workspace.panes.indices {
            workspace.panes[i].traceIDs.removeAll { $0 == id }
        }
        if selectedTraceID == id { selectedTraceID = workspace.traces.first?.id }
    }

    func binding(for traceID: UUID) -> Binding<Trace>? {
        guard let index = workspace.traces.firstIndex(where: { $0.id == traceID }) else { return nil }
        return Binding(
            get: { self.workspace.traces[index] },
            set: { self.workspace.traces[index] = $0; self.hasUnsavedChanges = true }
        )
    }

    func samples(for trace: Trace) -> TraceSamples {
        TraceEvaluator.samples(for: trace,
                               live: displayFrame,
                               memories: memoryLookup,
                               timeDomain: workspace.timeDomain,
                               groupDelayAperture: workspace.groupDelayAperture)
    }

    func autoScale(traceID: UUID) {
        guard let index = workspace.traces.firstIndex(where: { $0.id == traceID }) else { return }
        let s = samples(for: workspace.traces[index])
        guard !s.y.isEmpty else { return }
        let result = TraceEvaluator.autoScale(values: s.y, format: workspace.traces[index].format)
        workspace.traces[index].scalePerDivision = result.perDivision
        workspace.traces[index].referenceValue = result.referenceValue
        workspace.traces[index].referencePosition = result.referencePosition
    }

    func autoScaleAll() {
        for trace in workspace.traces { autoScale(traceID: trace.id) }
    }

    // MARK: - Markers

    func activeMarkerIndex() -> Int? {
        guard let id = activeMarkerID else { return nil }
        return workspace.markers.firstIndex { $0.id == id }
    }

    func addMarker() {
        let number = (workspace.markers.map(\.number).max() ?? 0) + 1
        guard number <= 8 else { return }
        var marker = Marker(number: number, frequency: displayFrame.centerFrequency)
        marker.enabled = true
        workspace.markers.append(marker)
        activeMarkerID = marker.id
    }

    func removeMarker(_ id: UUID) {
        workspace.markers.removeAll { $0.id == id }
        for i in workspace.markers.indices where workspace.markers[i].deltaReferenceID == id {
            workspace.markers[i].deltaReferenceID = nil
        }
        if activeMarkerID == id { activeMarkerID = workspace.markers.first?.id }
    }

    /// Give markers that have never been positioned (or that fell outside the sweep)
    /// a sensible spot inside the current span.
    func placeStrayMarkers() {
        guard !displayFrame.isEmpty else { return }
        let lo = displayFrame.startFrequency
        let hi = displayFrame.stopFrequency
        guard hi > lo else { return }
        let maxDistance = 1.0
        let strays = workspace.markers.indices.filter {
            workspace.markers[$0].frequency < lo || workspace.markers[$0].frequency > hi
        }
        guard !strays.isEmpty else { return }
        for (position, index) in strays.enumerated() {
            let t = Double(position + 1) / Double(strays.count + 1)
            workspace.markers[index].frequency = lo + (hi - lo) * t
            if workspace.markers[index].distance <= 0 {
                workspace.markers[index].distance = maxDistance * t
            }
        }
    }

    /// Re-evaluate markers that follow features of the data.
    func updateMarkerTracking() {
        guard !displayFrame.isEmpty else { return }
        for i in workspace.markers.indices {
            let marker = workspace.markers[i]
            guard marker.enabled, marker.tracking != .none else { continue }
            guard let traceID = marker.boundTraceID ?? workspace.traces.first?.id,
                  let trace = workspace.trace(id: traceID) else { continue }
            let s = samples(for: trace)
            guard !s.x.isEmpty, s.x.count == s.y.count else { continue }

            switch marker.tracking {
            case .none:
                break
            case .maximum:
                if let idx = TraceAnalysis.indexOfMaximum(s.y) { workspace.markers[i].frequency = s.x[idx] }
            case .minimum:
                if let idx = TraceAnalysis.indexOfMinimum(s.y) { workspace.markers[i].frequency = s.x[idx] }
            case .peakLeft:
                if let idx = TraceAnalysis.peaks(s.y).min() { workspace.markers[i].frequency = s.x[idx] }
            case .peakRight:
                if let idx = TraceAnalysis.peaks(s.y).max() { workspace.markers[i].frequency = s.x[idx] }
            case .bandwidthLower, .bandwidthUpper:
                if let bw = TraceAnalysis.bandwidth(values: s.y, frequencies: s.x, dropDB: 3,
                                                    searchMinimum: trace.format == .swr) {
                    workspace.markers[i].frequency = marker.tracking == .bandwidthLower ? bw.lower : bw.upper
                }
            case .resonance:
                let (values, frame) = TraceEvaluator.complexData(for: trace, live: displayFrame, memories: memoryLookup)
                if let f = TraceAnalysis.resonance(values: values, frequencies: frame.frequencies, z0: frame.z0) {
                    workspace.markers[i].frequency = f
                }
            }
        }
    }

    // MARK: - Panes

    func setLayout(_ layout: ChartLayout) {
        workspace.layout = layout
        workspace.ensurePaneCount()
        hasUnsavedChanges = true
    }

    func paneBinding(_ paneID: UUID) -> Binding<PlotPane>? {
        guard let index = workspace.panes.firstIndex(where: { $0.id == paneID }) else { return nil }
        return Binding(
            get: { self.workspace.panes[index] },
            set: { self.workspace.panes[index] = $0; self.hasUnsavedChanges = true }
        )
    }

    // MARK: - Console

    private func append(_ entry: TrafficLogEntry) {
        guard logTraffic else { return }
        trafficLog.append(entry)
        if trafficLog.count > 2000 { trafficLog.removeFirst(trafficLog.count - 2000) }
    }

    func clearLog() { trafficLog.removeAll() }

    func sendConsoleCommand(_ text: String) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        Task {
            do {
                _ = try await session.sendCommand(line, timeout: 8)
            } catch {
                append(TrafficLogEntry(direction: .error, text: error.localizedDescription))
            }
        }
    }

    // MARK: - Screenshot

    func captureDeviceScreen() {
        Task {
            do {
                let capture = try await session.captureScreen()
                lastScreenCapture = Self.image(from: capture)
                statusMessage = "Captured \(capture.width)×\(capture.height) screen"
            } catch {
                alertMessage = "Screen capture failed: \(error.localizedDescription)"
            }
        }
    }

    static func image(from capture: ScreenCapture) -> NSImage? {
        var pixels = capture.rgba
        guard let provider = CGDataProvider(data: Data(bytes: &pixels, count: pixels.count) as CFData),
              let cg = CGImage(width: capture.width, height: capture.height,
                               bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: capture.width * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: capture.width, height: capture.height))
    }

    // MARK: - Battery

    func refreshBattery() {
        Task {
            batteryMillivolts = try? await session.readBattery()
        }
    }
}
