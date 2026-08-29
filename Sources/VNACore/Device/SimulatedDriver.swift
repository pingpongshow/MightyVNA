import Foundation

/// A synthetic analyser used for demos, UI work and offline experimentation.
///
/// S11 models a dual-band antenna (145 MHz / 435 MHz) behind a short coax run;
/// S21 models a 300 MHz bandpass filter with finite insertion loss.
public final class SimulatedDriver: VNADriver {

    public private(set) var info: DeviceInfo
    public private(set) var isConnected = false
    public var trafficHandler: ((TrafficLogEntry) -> Void)?

    /// Random measurement noise, in linear reflection-coefficient units.
    public var noiseFloor: Double = 0.0015
    private var generator = SyntheticDUT.Noise()

    public static let model = DeviceModel(
        id: "simulator", name: "MightyVNA Simulator", vendor: "Built-in",
        wireProtocol: .asciiShell,
        minFrequency: 10_000, maxFrequency: 6e9, fundamentalMax: nil,
        maxHardwarePoints: 1001, defaultPoints: 401, screen: ScreenSize(480, 320),
        supportsScreenshot: true, supportsBattery: true,
        notes: "Synthetic data source: a dual-band antenna on CH0 and a 300 MHz bandpass filter on CH1."
    )

    public init() {
        info = DeviceInfo(model: Self.model, portPath: "simulator")
        info.firmwareVersion = "MightyVNA simulator 1.0"
        info.banner = "Simulated device — no hardware required"
        info.supportedCommands = ["version", "info", "help", "sweep", "scan", "data", "frequencies",
                                  "capture", "vbat", "pause", "resume", "cal", "save", "recall"]
        info.batteryMillivolts = 4020
    }

    public func connect() throws {
        isConnected = true
        trafficHandler?(TrafficLogEntry(direction: .note, text: "Connected to the built-in simulator"))
    }

    public func disconnect() {
        isConnected = false
    }

    public func sweep(start: Double, stop: Double, points: Int) throws -> SweepFrame {
        guard isConnected else { throw DriverError.notConnected }
        let n = max(2, min(points, info.model.maxHardwarePoints))
        let step = n > 1 ? (stop - start) / Double(n - 1) : 0
        var frequencies = [Double](repeating: 0, count: n)
        var s11 = [Complex](repeating: .zero, count: n)
        var s21 = [Complex](repeating: .zero, count: n)

        for i in 0..<n {
            let f = start + step * Double(i)
            frequencies[i] = f
            s11[i] = simulatedS11(at: f) + noise()
            s21[i] = simulatedS21(at: f) + noise()
        }
        // Pretend to take time, so the UI's live behaviour is realistic.
        Thread.sleep(forTimeInterval: min(0.35, 0.0004 * Double(n)))
        return SweepFrame(frequencies: frequencies, s11: s11, s21: s21)
    }

    // MARK: - The synthetic DUT

    private func simulatedS11(at f: Double) -> Complex { SyntheticDUT.antennaS11(at: f) }
    private func simulatedS21(at f: Double) -> Complex { SyntheticDUT.filterS21(at: f) }

    private func noise() -> Complex { generator.complex(amplitude: noiseFloor) }

    // MARK: - Passthrough

    public func sendRaw(_ line: String, timeout: TimeInterval) throws -> String {
        let command = line.trimmingCharacters(in: .whitespaces)
        switch command.split(separator: " ").first.map(String.init) ?? "" {
        case "version": return info.firmwareVersion
        case "info": return "Board: MightyVNA simulator\nBuild time: compiled in\nPlatform: macOS"
        case "help": return info.supportedCommands.sorted().joined(separator: " ")
        case "vbat": return "4020 mV"
        case "": return ""
        default: return "simulator: '\(command)' acknowledged"
        }
    }

    public func captureScreen() throws -> ScreenCapture {
        let size = info.model.screen ?? ScreenSize(480, 320)
        var rgba = [UInt8](repeating: 255, count: size.width * size.height * 4)
        for y in 0..<size.height {
            for x in 0..<size.width {
                let i = (y * size.width + x) * 4
                // A simple gradient with a grid, standing in for the instrument screen.
                let onGrid = x % (size.width / 10) == 0 || y % (size.height / 10) == 0
                rgba[i + 0] = onGrid ? 90 : UInt8(20 + 30 * x / size.width)
                rgba[i + 1] = onGrid ? 110 : UInt8(24 + 40 * y / size.height)
                rgba[i + 2] = onGrid ? 130 : 48
                rgba[i + 3] = 255
            }
        }
        return ScreenCapture(width: size.width, height: size.height, rgba: rgba)
    }

    public func readBattery() throws -> Int? { info.batteryMillivolts }
    public func pause() throws {}
    public func resume() throws {}
}

