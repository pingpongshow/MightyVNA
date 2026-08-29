import Foundation

/// Sweep request as configured in the UI.
public struct SweepConfiguration: Codable, Equatable, Sendable {
    public var start: Double
    public var stop: Double
    /// Total points across all segments.
    public var points: Int
    /// Extra hardware averaging (V2) or repeated sweeps (ASCII) per acquisition.
    public var samplesPerPoint: Int

    public init(start: Double = 1e6, stop: Double = 900e6, points: Int = 201, samplesPerPoint: Int = 1) {
        self.start = start
        self.stop = stop
        self.points = points
        self.samplesPerPoint = samplesPerPoint
    }

    public var span: Double { stop - start }
    public var center: Double { (start + stop) / 2 }

    public var stepSize: Double {
        points > 1 ? (stop - start) / Double(points - 1) : 0
    }

    public func frequencyGrid() -> [Double] {
        guard points > 1 else { return [start] }
        let step = stepSize
        return (0..<points).map { start + step * Double($0) }
    }

    /// Clamp to the connected hardware's limits.
    public func clamped(to model: DeviceModel) -> SweepConfiguration {
        var c = self
        c.start = max(model.minFrequency, min(start, model.maxFrequency))
        c.stop = max(c.start + 1, min(stop, model.maxFrequency))
        c.points = max(2, min(points, 10_001))
        return c
    }

    /// How many hardware sweeps are needed for this request.
    public func segmentCount(for model: DeviceModel) -> Int {
        let maxPoints = max(2, model.maxHardwarePoints)
        return Int(ceil(Double(points) / Double(maxPoints)))
    }
}

/// Runs blocking serial work on a dedicated queue and bridges it to async/await.
public final class SerialWorker: @unchecked Sendable {
    private let queue: DispatchQueue

    public init(label: String = "com.mightyvna.serial") {
        self.queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    public func perform<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

public enum ConnectionPreference: String, CaseIterable, Sendable, Identifiable {
    case automatic
    case asciiShell
    case binaryV2
    case libreVNA
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .automatic: return "Detect automatically"
        case .asciiShell: return "ASCII shell (NanoVNA / -H / -F)"
        case .binaryV2: return "Binary V2 (V2 / LiteVNA / SV)"
        case .libreVNA: return "LibreVNA (USB packet protocol)"
        }
    }
    /// Preferences that only apply to serial-port devices.
    public var isSerial: Bool { self == .asciiShell || self == .binaryV2 }
}

/// Anything MightyVNA can connect to: a serial port, or a raw USB instrument.
public enum DiscoveredDevice: Identifiable, Hashable, Sendable {
    case serial(SerialPortInfo)
    case usb(USBDeviceInfo)

    public var id: String {
        switch self {
        case .serial(let port): return "serial:" + port.path
        case .usb(let device): return device.id
        }
    }

    public var displayName: String {
        switch self {
        case .serial(let port): return port.displayName
        case .usb(let device): return device.displayName
        }
    }

    /// Short second line for the picker.
    public var detail: String {
        switch self {
        case .serial(let port): return "\(port.name) · USB \(port.identifierString)"
        case .usb(let device): return "USB \(device.identifierString) · bulk endpoints"
        }
    }

    public var isUSB: Bool { if case .usb = self { return true }; return false }

    /// The protocol this endpoint is known to speak, when that is already certain.
    public var knownProtocol: WireProtocol? {
        switch self {
        case .serial: return nil        // could be either NanoVNA protocol; probe to find out
        case .usb(let device):
            return LibreVNADriver.usbIdentifiers.contains(where: {
                $0.vendor == device.vendorID && $0.product == device.productID
            }) ? .libreVNA : nil
        }
    }
}

/// Owns the active driver and serialises every device interaction.
public final class DeviceSession: @unchecked Sendable {

    private let worker = SerialWorker()
    private var driver: VNADriver?
    public private(set) var info: DeviceInfo?
    /// Called on an arbitrary queue for every protocol exchange.
    public var trafficHandler: ((TrafficLogEntry) -> Void)?
    /// Called with progress 0...1 while a segmented sweep runs.
    public var progressHandler: ((Double) -> Void)?

    public init() {}

    public var isConnected: Bool { driver?.isConnected ?? false }

    /// Attach a driver directly. Used by the tests to exercise sweep segmentation
    /// without a serial port.
    public func attachForTesting(_ driver: VNADriver) {
        self.driver = driver
        self.info = driver.info
    }

    /// Live device info, including limits the driver has learned since connecting.
    public var currentInfo: DeviceInfo? { driver?.info }

    // MARK: - Discovery

    public func discoverPorts() -> [SerialPortInfo] {
        SerialPortEnumerator.candidatePorts()
    }

    /// Every analyser-shaped endpoint on the machine: serial ports plus raw-USB instruments.
    public func discoverDevices() -> [DiscoveredDevice] {
        let usb = IOKitUSBBulkDevice.discover(identifiers: LibreVNADriver.usbIdentifiers)
            .map { DiscoveredDevice.usb($0) }
        let serial = SerialPortEnumerator.candidatePorts().map { DiscoveredDevice.serial($0) }
        // Raw-USB instruments are unambiguous, so they sort first.
        return usb + serial
    }

    public func connect(to device: DiscoveredDevice,
                        preference: ConnectionPreference = .automatic) async throws -> DeviceInfo {
        switch device {
        case .usb(let usb):
            return try await connectUSB(usb)
        case .serial(let port):
            return try await connectSerial(port, preference: preference)
        }
    }

    /// LibreVNA and anything else reached over raw USB bulk endpoints.
    private func connectUSB(_ usb: USBDeviceInfo) async throws -> DeviceInfo {
        await disconnect()
        let handler = trafficHandler
        let connected: (VNADriver, DeviceInfo) = try await worker.perform {
            let candidate = LibreVNADriver(usb: usb)
            candidate.trafficHandler = handler
            do {
                try candidate.connect()
            } catch {
                candidate.disconnect()
                throw error
            }
            return (candidate, candidate.info)
        }
        driver = connected.0
        info = connected.1
        return connected.1
    }

    private func connectSerial(_ port: SerialPortInfo,
                               preference: ConnectionPreference) async throws -> DeviceInfo {
        await disconnect()
        let handler = trafficHandler
        let path = port.path

        let connected: (VNADriver, DeviceInfo) = try await worker.perform {
            var attempts: [VNADriver] = []
            switch preference {
            case .automatic, .libreVNA:
                attempts = [ASCIIShellDriver(portPath: path), V2BinaryDriver(portPath: path)]
            case .asciiShell:
                attempts = [ASCIIShellDriver(portPath: path)]
            case .binaryV2:
                attempts = [V2BinaryDriver(portPath: path)]
            }

            var lastError: Error?
            for candidate in attempts {
                candidate.trafficHandler = handler
                do {
                    try candidate.connect()
                    if Self.looksValid(candidate) {
                        return (candidate, candidate.info)
                    }
                    candidate.disconnect()
                    lastError = DriverError.badResponse("device did not answer the \(type(of: candidate)) handshake")
                } catch {
                    candidate.disconnect()
                    lastError = error
                }
            }
            throw lastError ?? DriverError.notConnected
        }

        driver = connected.0
        info = connected.1
        return connected.1
    }

    private static func looksValid(_ driver: VNADriver) -> Bool {
        if let ascii = driver as? ASCIIShellDriver {
            return !ascii.info.banner.isEmpty || !ascii.info.supportedCommands.isEmpty
        }
        if driver is V2BinaryDriver {
            return driver.info.model.id != DeviceCatalog.genericV2.id || !driver.info.banner.isEmpty
        }
        return true
    }

    /// Attach the built-in synthetic device, so every feature works without hardware.
    public func connectSimulator() async throws -> DeviceInfo {
        await disconnect()
        let handler = trafficHandler
        let connected: (VNADriver, DeviceInfo) = try await worker.perform {
            let sim = SimulatedDriver()
            sim.trafficHandler = handler
            try sim.connect()
            return (sim, sim.info)
        }
        driver = connected.0
        info = connected.1
        return connected.1
    }

    /// Attach the in-process LibreVNA emulator: a synthetic two-port instrument that
    /// exercises S12, S22 and the full two-port calibration.
    public func connectLibreVNASimulator() async throws -> DeviceInfo {
        await disconnect()
        let handler = trafficHandler
        let connected: (VNADriver, DeviceInfo) = try await worker.perform {
            let driver = LibreVNADriver.simulated()
            driver.trafficHandler = handler
            try driver.connect()
            return (driver, driver.info)
        }
        driver = connected.0
        info = connected.1
        return connected.1
    }

    public func disconnect() async {
        guard let current = driver else { return }
        driver = nil
        info = nil
        try? await worker.perform { current.disconnect() }
    }

    // MARK: - Sweeping

    /// Run one acquisition, splitting into hardware-sized segments when needed.
    public func sweep(_ configuration: SweepConfiguration) async throws -> SweepFrame {
        guard let current = driver else { throw DriverError.notConnected }
        let model = current.info.model
        let config = configuration.clamped(to: model)
        let progress = progressHandler

        return try await worker.perform {
            if config.points <= max(2, current.info.model.maxHardwarePoints) {
                progress?(0)
                var frame = try current.sweep(start: config.start, stop: config.stop, points: config.points)
                frame.timestamp = Date()
                progress?(1)
                return frame
            }

            // Segmented sweep: walk the span in contiguous chunks. The chunk size is
            // re-read every pass, because a driver can discover the device's real
            // point limit while the first segment runs.
            let step = config.stepSize
            var frequencies: [Double] = []
            var s11: [Complex] = []
            var s21: [Complex] = []
            frequencies.reserveCapacity(config.points)

            var index = 0
            var passes = 0
            while index < config.points {
                let limit = max(2, current.info.model.maxHardwarePoints)
                let requested = min(limit, config.points - index)
                let segmentStart = config.start + step * Double(index)
                let segmentStop = segmentStart + step * Double(max(0, requested - 1))
                let part = try current.sweep(start: segmentStart, stop: segmentStop, points: requested)

                // Trust the requested grid over the reported one: some firmware rounds
                // the frequencies it echoes back.
                let received = min(part.count, requested)
                guard received > 0 else {
                    throw DriverError.badResponse("a sweep segment returned no data")
                }
                frequencies.append(contentsOf: (0..<received).map { segmentStart + step * Double($0) })
                s11.append(contentsOf: part.s11.prefix(received))
                s21.append(contentsOf: part.s21.prefix(received))
                index += received

                progress?(Double(index) / Double(config.points))
                passes += 1
                if passes > 256 {
                    throw DriverError.protocolError("segmented sweep did not converge after \(passes) passes")
                }
            }
            return SweepFrame(frequencies: frequencies, s11: s11, s21: s21, timestamp: Date())
        }
    }

    // MARK: - LibreVNA-specific settings

    /// Acquisition settings that only exist on the LibreVNA.
    public struct LibreVNASettings: Equatable, Sendable {
        public var ifBandwidth: UInt32 = 1_000
        /// Excitation level in 1/100 dBm.
        public var excitationCdBm: Int16 = -1_000
        /// Measure the reverse direction. Off halves the sweep time but loses S12 and S22.
        public var measureReverse = true
        public var logarithmicSweep = false
        /// Limits reported by the hardware, for clamping the UI.
        public var minIFBandwidth: UInt32 = 10
        public var maxIFBandwidth: UInt32 = 50_000
        public var cdbmMin: Int16 = -4_000
        public var cdbmMax: Int16 = 0
        public init() {}
    }

    public func libreVNASettings() async -> LibreVNASettings? {
        guard let driver = libreVNA else { return nil }
        return try? await worker.perform {
            var settings = LibreVNASettings()
            settings.ifBandwidth = driver.ifBandwidth
            settings.excitationCdBm = driver.excitationCdBm
            settings.measureReverse = driver.measureReverse
            settings.logarithmicSweep = driver.logarithmicSweep
            let limits = driver.deviceLimits
            if limits.minIFBandwidth > 0 { settings.minIFBandwidth = limits.minIFBandwidth }
            if limits.maxIFBandwidth > 0 { settings.maxIFBandwidth = limits.maxIFBandwidth }
            if limits.cdbmMin != 0 || limits.cdbmMax != 0 {
                settings.cdbmMin = limits.cdbmMin
                settings.cdbmMax = limits.cdbmMax
            }
            return settings
        }
    }

    /// Push new settings to the driver on its own queue, so no sweep is mid-flight.
    public func applyLibreVNASettings(_ settings: LibreVNASettings) async {
        guard let driver = libreVNA else { return }
        _ = try? await worker.perform {
            driver.ifBandwidth = min(max(settings.ifBandwidth, settings.minIFBandwidth), settings.maxIFBandwidth)
            driver.excitationCdBm = min(max(settings.excitationCdBm, settings.cdbmMin), settings.cdbmMax)
            driver.measureReverse = settings.measureReverse
            driver.logarithmicSweep = settings.logarithmicSweep
        }
    }

    // MARK: - Passthrough

    public func sendCommand(_ line: String, timeout: TimeInterval = 4) async throws -> String {
        guard let current = driver else { throw DriverError.notConnected }
        return try await worker.perform { try current.sendRaw(line, timeout: timeout) }
    }

    public var isSimulated: Bool { driver is SimulatedDriver || (driver as? LibreVNADriver)?.info.portPath == "librevna-simulator" }

    /// The LibreVNA driver, when one is connected, for protocol-specific settings.
    public var libreVNA: LibreVNADriver? { driver as? LibreVNADriver }

    /// True when the connected instrument measures the reverse direction.
    public var isFullTwoPort: Bool { driver?.info.model.isFullTwoPort ?? false }

    public func captureScreen() async throws -> ScreenCapture {
        guard let current = driver else { throw DriverError.notConnected }
        return try await worker.perform { try current.captureScreen() }
    }

    public func readBattery() async throws -> Int? {
        guard let current = driver else { throw DriverError.notConnected }
        return try await worker.perform { try current.readBattery() }
    }

    public func pauseDevice() async throws {
        guard let current = driver else { throw DriverError.notConnected }
        try await worker.perform { try current.pause() }
    }

    public func resumeDevice() async throws {
        guard let current = driver else { throw DriverError.notConnected }
        try await worker.perform { try current.resume() }
    }

    /// On-device calibration passthrough (ASCII firmware only).
    public func deviceCalibration(_ subcommand: String) async throws -> String {
        guard let ascii = driver as? ASCIIShellDriver else {
            throw DriverError.unsupported("on-device calibration commands")
        }
        return try await worker.perform { try ascii.deviceCalibration(subcommand) }
    }

    public func saveDeviceSlot(_ slot: Int) async throws {
        guard let ascii = driver as? ASCIIShellDriver else { throw DriverError.unsupported("device memory slots") }
        try await worker.perform { try ascii.saveDeviceSlot(slot) }
    }

    public func recallDeviceSlot(_ slot: Int) async throws {
        guard let ascii = driver as? ASCIIShellDriver else { throw DriverError.unsupported("device memory slots") }
        try await worker.perform { try ascii.recallDeviceSlot(slot) }
    }

    public var supportsTextCommands: Bool { driver is ASCIIShellDriver || driver is SimulatedDriver }
    public var supportsScreenCapture: Bool {
        guard let d = driver else { return false }
        return (d is ASCIIShellDriver || d is SimulatedDriver) && d.info.model.supportsScreenshot
    }
}
