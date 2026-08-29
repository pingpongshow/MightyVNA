import SwiftUI
import AppKit
import VNACore
import UniformTypeIdentifiers

extension UTType {
    static let mightyVNASession = UTType(exportedAs: "com.mightyvna.session", conformingTo: .json)
    static let touchstone1Port = UTType(filenameExtension: "s1p") ?? .plainText
    static let touchstone2Port = UTType(filenameExtension: "s2p") ?? .plainText
}

extension AppModel {

    // MARK: - Session documents

    func newSession() {
        workspace = .makeDefault()
        calibration = Calibration()
        memories = []
        documentURL = nil
        hasUnsavedChanges = false
        statusMessage = "New session"
    }

    func saveSession() {
        if let url = documentURL {
            write(to: url)
        } else {
            saveSessionAs()
        }
    }

    func saveSessionAs() {
        let panel = NSSavePanel()
        panel.title = "Save MightyVNA Session"
        panel.nameFieldStringValue = "Session.mightyvna"
        panel.allowedContentTypes = [.mightyVNASession]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(to: url)
    }

    private func write(to url: URL) {
        var document = SessionDocument()
        document.workspace = workspace
        document.calibration = calibration.isSolved || !calibration.measurements.isEmpty ? calibration : nil
        document.liveFrame = displayFrame.isEmpty ? nil : displayFrame
        document.memories = memories
        document.deviceDescription = deviceInfo.map { "\($0.model.name) · \($0.firmwareVersion)" } ?? ""
        do {
            try document.encoded().write(to: url, options: .atomic)
            documentURL = url
            hasUnsavedChanges = false
            statusMessage = "Saved \(url.lastPathComponent)"
        } catch {
            alertMessage = "Could not save the session: \(error.localizedDescription)"
        }
    }

    func openSession() {
        let panel = NSOpenPanel()
        panel.title = "Open MightyVNA Session"
        panel.allowedContentTypes = [.mightyVNASession, .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let document = try SessionDocument.decode(try Data(contentsOf: url))
            workspace = document.workspace
            workspace.ensurePaneCount()
            calibration = document.calibration ?? Calibration()
            memories = document.memories
            if let frame = document.liveFrame { loadFrameForDisplay(frame) }
            documentURL = url
            hasUnsavedChanges = false
            selectedTraceID = workspace.traces.first?.id
            activeMarkerID = workspace.markers.first?.id
            statusMessage = "Opened \(url.lastPathComponent)"
        } catch {
            alertMessage = "Could not open the session: \(error.localizedDescription)"
        }
    }

    // MARK: - Touchstone

    func exportTouchstone(ports: Int) {
        guard !displayFrame.isEmpty else {
            alertMessage = "There is no sweep to export yet."
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Touchstone"
        let ext = ports == 1 ? "s1p" : "s2p"
        panel.nameFieldStringValue = "measurement.\(ext)"
        panel.allowedContentTypes = [ports == 1 ? .touchstone1Port : .touchstone2Port]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var options = Touchstone.WriteOptions()
        options.ports = ports
        options.format = .realImaginary
        options.frequencyUnit = .hz
        options.assumeReciprocal = ports == 2
        options.comments = [
            "Device: \(deviceInfo?.model.name ?? "unknown")",
            "Calibration: \(calibration.isSolved ? calibration.summary : "none (raw data)")",
            ports == 2 ? "S12 is a copy of S21 (reciprocity assumed); S22 is not measured by this instrument." : ""
        ].filter { !$0.isEmpty }

        do {
            try Touchstone.string(from: displayFrame, options: options).write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "Exported \(url.lastPathComponent)"
        } catch {
            alertMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    func exportCSV() {
        guard !displayFrame.isEmpty else {
            alertMessage = "There is no sweep to export yet."
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export CSV"
        panel.nameFieldStringValue = "measurement.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Touchstone.csv(from: displayFrame).write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "Exported \(url.lastPathComponent)"
        } catch {
            alertMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    func importTouchstone() {
        let panel = NSOpenPanel()
        panel.title = "Import Touchstone"
        panel.allowedContentTypes = [.touchstone1Port, .touchstone2Port, .plainText, .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            var frame = try Touchstone.parse(text, label: url.lastPathComponent)
            frame.id = UUID()
            loadFrameForDisplay(frame)
            memories.append(frame)
            workspace.sweep.start = frame.startFrequency
            workspace.sweep.stop = frame.stopFrequency
            workspace.sweep.points = frame.count
            statusMessage = "Imported \(url.lastPathComponent) · \(frame.count) points"
        } catch {
            alertMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    /// Push a frame straight into the display path (used by import and session load).
    func loadFrameForDisplay(_ frame: SweepFrame) {
        setFrames(raw: frame, display: frame)
    }

    // MARK: - Screenshot export

    func saveDeviceScreenshot() {
        guard let image = lastScreenCapture else {
            alertMessage = "Capture the instrument screen first."
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save Instrument Screenshot"
        panel.nameFieldStringValue = "nanovna-screen.png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            alertMessage = "Could not encode the screenshot."
            return
        }
        do {
            try png.write(to: url)
            statusMessage = "Saved \(url.lastPathComponent)"
        } catch {
            alertMessage = "Could not save the screenshot: \(error.localizedDescription)"
        }
    }

    /// Write an arbitrary rendered image (used for plot export).
    func savePNG(_ image: NSImage, suggestedName: String) {
        let panel = NSSavePanel()
        panel.title = "Export Plot"
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
        statusMessage = "Exported \(url.lastPathComponent)"
    }

    // MARK: - Calibration files

    func saveCalibration() {
        guard calibration.isSolved else {
            alertMessage = "Complete at least the open, short and load steps before saving."
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save Calibration"
        panel.nameFieldStringValue = "calibration.mvnacal"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(calibration).write(to: url, options: .atomic)
            statusMessage = "Saved calibration \(url.lastPathComponent)"
        } catch {
            alertMessage = "Could not save the calibration: \(error.localizedDescription)"
        }
    }

    func loadCalibration() {
        let panel = NSOpenPanel()
        panel.title = "Load Calibration"
        panel.allowedContentTypes = [.json, .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var loaded = try decoder.decode(Calibration.self, from: try Data(contentsOf: url))
            loaded.solve()
            calibration = loaded
            reprocessCurrentFrame()
            statusMessage = "Loaded calibration \(loaded.frequencyRangeDescription)"
        } catch {
            alertMessage = "Could not load the calibration: \(error.localizedDescription)"
        }
    }
}

// MARK: - Plot image export

extension AppModel {
    /// Render the current plot grid to a PNG at a fixed, print-friendly size.
    func exportPlotImage() {
        guard !displayFrame.isEmpty else {
            alertMessage = "There is no sweep to export yet."
            return
        }
        let content = PlotGridView()
            .environmentObject(self)
            .frame(width: 1600, height: 1000)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage else {
            alertMessage = "Could not render the plots."
            return
        }
        savePNG(image, suggestedName: "mightyvna-plot.png")
    }
}
