import Foundation

/// Driver for the LibreVNA — a full two-port analyser that speaks a packet protocol over
/// vendor-specific USB bulk endpoints rather than a serial port.
///
/// Unlike every NanoVNA, this instrument measures the reverse direction, so a sweep
/// returns real S12 and S22 alongside S11 and S21.
public final class LibreVNADriver: VNADriver {

    /// USB identifiers used by LibreVNA firmware.
    public static let usbIdentifiers: [(vendor: Int, product: Int)] = [
        (0x0483, 0x564E),
        (0x0483, 0x4121)
    ]
    public static let dataOutEndpoint: UInt8 = 0x01
    public static let dataInEndpoint: UInt8 = 0x81

    public private(set) var info: DeviceInfo
    public var isConnected: Bool { transport.isOpen }
    public var trafficHandler: ((TrafficLogEntry) -> Void)?

    private let transport: USBBulkTransport
    private var receiveBuffer = Data()

    /// Sweep configuration exposed to the UI.
    public var ifBandwidth: UInt32 = 1_000
    /// Excitation level in 1/100 dBm.
    public var excitationCdBm: Int16 = -1_000
    /// Measure the reverse direction too. Turning this off halves the sweep time.
    public var measureReverse = true
    public var logarithmicSweep = false

    public private(set) var deviceLimits = LibreVNA.DeviceInfo()
    public private(set) var lastStatus: LibreVNA.DeviceStatus?

    public convenience init(usb: USBDeviceInfo) {
        self.init(transport: IOKitUSBBulkDevice(info: usb,
                                                outEndpoint: LibreVNADriver.dataOutEndpoint,
                                                inEndpoint: LibreVNADriver.dataInEndpoint),
                  portDescription: usb.id,
                  model: DeviceCatalog.libreVNA)
    }

    public init(transport: USBBulkTransport,
                portDescription: String,
                model: DeviceModel = DeviceCatalog.libreVNA) {
        self.transport = transport
        self.info = DeviceInfo(model: model, portPath: portDescription)
    }

    // MARK: - Connection

    public func connect() throws {
        try transport.open()
        log(.note, "Opened LibreVNA USB interface")
        receiveBuffer.removeAll()

        // Stop anything the device was doing, then ask who it is.
        try send(.setIdle)
        try send(.stopStatusUpdates)
        drainPending(for: 0.1)

        try send(.requestDeviceInfo)
        guard let packet = try waitForPacket(ofType: .deviceInfo, timeout: 2.5),
              let limits = LibreVNA.DeviceInfo(payload: packet.payload) else {
            transport.close()
            throw DriverError.badResponse("the device did not return a LibreVNA device-info packet")
        }
        adopt(limits)
        log(.note, "Identified as \(info.model.name) firmware \(limits.firmwareDescription)")

        try? send(.requestDeviceStatus)
        if let status = try? waitForPacket(ofType: .deviceStatus, timeout: 0.6),
           let decoded = LibreVNA.DeviceStatus(payload: status.payload) {
            lastStatus = decoded
        }
    }

    private func adopt(_ limits: LibreVNA.DeviceInfo) {
        deviceLimits = limits
        var model = info.model
        if limits.minFrequency > 0 { model.minFrequency = Double(limits.minFrequency) }
        if limits.maxFrequency > 0 { model.maxFrequency = Double(limits.maxFrequency) }
        if limits.maxPoints > 0 { model.maxHardwarePoints = Int(limits.maxPoints) }
        model.portCount = max(1, Int(limits.portCount))
        model.isFullTwoPort = model.portCount >= 2
        model.defaultPoints = min(501, model.maxHardwarePoints)
        info.model = model
        info.firmwareVersion = limits.firmwareDescription
        info.hardwareRevision = "v\(limits.hardwareVersion)\(limits.hardwareRevision)"
        info.protocolVersion = "\(limits.protocolVersion)"
        info.banner = "LibreVNA \(limits.firmwareDescription) · hardware \(limits.hardwareVersion)\(limits.hardwareRevision) "
                    + "· \(limits.portCount) ports · \(Units.frequencyShort(Double(limits.minFrequency))) – "
                    + "\(Units.frequencyShort(Double(limits.maxFrequency))) · up to \(limits.maxPoints) points"
        info.supportedCommands = []

        // Keep the IF bandwidth and excitation inside what the hardware accepts.
        if limits.minIFBandwidth > 0 {
            ifBandwidth = min(max(ifBandwidth, limits.minIFBandwidth), max(limits.maxIFBandwidth, limits.minIFBandwidth))
        }
        if limits.cdbmMin != 0 || limits.cdbmMax != 0 {
            excitationCdBm = min(max(excitationCdBm, limits.cdbmMin), limits.cdbmMax)
        }
    }

    public func disconnect() {
        if transport.isOpen {
            try? send(.setIdle)
        }
        transport.close()
        log(.note, "Closed LibreVNA USB interface")
    }

    // MARK: - Sweeping

    public func sweep(start: Double, stop: Double, points: Int) throws -> SweepFrame {
        guard transport.isOpen else { throw DriverError.notConnected }
        let n = max(2, min(points, info.model.maxHardwarePoints))
        let twoPort = measureReverse && info.model.portCount >= 2

        var settings = LibreVNA.SweepSettings()
        settings.startHz = UInt64(max(0, start.rounded()))
        settings.stopHz = UInt64(max(start + 1, stop).rounded())
        settings.points = UInt16(n)
        settings.ifBandwidth = ifBandwidth
        settings.cdbmStart = excitationCdBm
        settings.cdbmStop = excitationCdBm
        settings.logSweep = logarithmicSweep
        settings.suppressPeaks = true
        settings.fixedPowerSetting = true
        settings.stages = twoPort ? 1 : 0
        settings.port1Stage = 0
        settings.port2Stage = twoPort ? 1 : 0

        // Stop any free-running sweep and flush packets still in flight, so points from the
        // previous acquisition cannot be mistaken for the start of this one.
        try send(.setIdle)
        drainPending(for: 0.08)
        receiveBuffer.removeAll()

        try send(.sweepSettings, payload: settings.encoded())
        log(.sent, "sweep \(settings.startHz) – \(settings.stopHz) Hz × \(n) points, "
                 + "IF BW \(ifBandwidth) Hz, \(twoPort ? "forward + reverse" : "forward only")")

        var frequencies = [Double](repeating: 0, count: n)
        var s11 = [Complex](repeating: .zero, count: n)
        var s21 = [Complex](repeating: .zero, count: n)
        var s12 = [Complex](repeating: .zero, count: n)
        var s22 = [Complex](repeating: .zero, count: n)
        var filled = [Bool](repeating: false, count: n)
        var remaining = n
        var started = false

        // Sweep time is roughly points × stages / IF bandwidth, plus settling.
        let stages = twoPort ? 2.0 : 1.0
        let estimate = Double(n) * stages / Double(max(1, ifBandwidth)) * 4 + 5
        let deadline = Date().addingTimeInterval(min(max(estimate, 8), 180))

        while remaining > 0 {
            guard Date() < deadline else {
                try? send(.setIdle)
                throw DriverError.protocolError(
                    "timed out after receiving \(n - remaining) of \(n) points. "
                    + "Try a narrower sweep, fewer points or a wider IF bandwidth.")
            }
            for packet in try receivePackets(timeout: 0.25) {
                switch packet.type {
                case .vnaDatapoint:
                    guard let point = LibreVNA.Datapoint(payload: packet.payload) else { continue }
                    let index = Int(point.pointNumber)
                    guard index < n else { continue }
                    // Wait for the start of a sweep so we never stitch two together.
                    if !started {
                        if index != 0 { continue }
                        started = true
                    }
                    if !filled[index] {
                        filled[index] = true
                        remaining -= 1
                    }
                    frequencies[index] = Double(point.frequency)
                    s11[index] = point.sParameter(receivePort: 1, excitePort: 1, stage: 0) ?? .zero
                    s21[index] = point.sParameter(receivePort: 2, excitePort: 1, stage: 0) ?? .zero
                    if twoPort {
                        s12[index] = point.sParameter(receivePort: 1, excitePort: 2, stage: 1) ?? .zero
                        s22[index] = point.sParameter(receivePort: 2, excitePort: 2, stage: 1) ?? .zero
                    }
                case .deviceStatus:
                    lastStatus = LibreVNA.DeviceStatus(payload: packet.payload)
                case .nack:
                    try? send(.setIdle)
                    throw DriverError.protocolError("the device rejected the sweep settings")
                default:
                    break
                }
            }
        }

        try? send(.setIdle)

        // Some firmware reports 0 Hz on the first point of a log sweep; fall back to the request.
        if frequencies.contains(where: { $0 <= 0 }) {
            let step = n > 1 ? (stop - start) / Double(n - 1) : 0
            for i in 0..<n where frequencies[i] <= 0 { frequencies[i] = start + step * Double(i) }
        }

        log(.received, "\(n) points\(twoPort ? " (4 S-parameters)" : "")")
        return SweepFrame(frequencies: frequencies,
                          s11: s11, s21: s21,
                          s12: twoPort ? s12 : [],
                          s22: twoPort ? s22 : [])
    }

    public func pause() throws {
        guard transport.isOpen else { return }
        try send(.setIdle)
    }

    public func resume() throws {}

    // MARK: - Unsupported operations

    public func sendRaw(_ line: String, timeout: TimeInterval) throws -> String {
        // The protocol is binary, but a few useful queries can be issued by name.
        switch line.trimmingCharacters(in: .whitespaces).lowercased() {
        case "info", "version":
            return info.banner
        case "status":
            try send(.requestDeviceStatus)
            if let packet = try waitForPacket(ofType: .deviceStatus, timeout: 1.0),
               let status = LibreVNA.DeviceStatus(payload: packet.payload) {
                lastStatus = status
                return "Status: \(status.summary)\nSource \(status.temperatureSource) °C, "
                     + "LO \(status.temperatureLO) °C, MCU \(status.temperatureMCU) °C"
            }
            return "No status response."
        case "idle":
            try send(.setIdle)
            return "Device set to idle."
        default:
            throw DriverError.unsupported(
                "text commands (the LibreVNA uses a binary packet protocol). "
                + "Recognised words here: info, status, idle.")
        }
    }

    public func captureScreen() throws -> ScreenCapture {
        throw DriverError.unsupported("screen capture (the LibreVNA has no display)")
    }

    public func readBattery() throws -> Int? { nil }

    // MARK: - Packet plumbing

    private func send(_ type: LibreVNA.PacketType, payload: Data = Data()) throws {
        let data = LibreVNA.encode(LibreVNA.Packet(type: type, payload: payload))
        try transport.write(data, timeout: 1.0)
    }

    private func receivePackets(timeout: TimeInterval) throws -> [LibreVNA.Packet] {
        let chunk = try transport.read(maxBytes: 65536, timeout: timeout)
        if !chunk.isEmpty { receiveBuffer.append(chunk) }
        guard !receiveBuffer.isEmpty else { return [] }
        // Guard against a runaway buffer if the stream desynchronises badly.
        if receiveBuffer.count > 4 * 1024 * 1024 {
            receiveBuffer.removeFirst(receiveBuffer.count - 65536)
        }
        return LibreVNA.drain(&receiveBuffer)
    }

    private func waitForPacket(ofType type: LibreVNA.PacketType,
                               timeout: TimeInterval) throws -> LibreVNA.Packet? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for packet in try receivePackets(timeout: 0.15) where packet.type == type {
                return packet
            }
        }
        return nil
    }

    private func drainPending(for duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            _ = try? receivePackets(timeout: 0.05)
        }
    }

    private func log(_ direction: TrafficLogEntry.Direction, _ text: String) {
        trafficHandler?(TrafficLogEntry(direction: direction, text: text))
    }
}
