import Foundation

/// Driver for the NanoVNA V2 register protocol, also used by the V2 Plus4,
/// LiteVNA and the SYSJOINT SV series.
///
/// The device exposes a flat register file; sweeps are configured by writing
/// start/step/points and then draining a 32-byte-per-point FIFO.
public final class V2BinaryDriver: VNADriver {

    public private(set) var info: DeviceInfo
    public var isConnected: Bool { port.isOpen }
    public var trafficHandler: ((TrafficLogEntry) -> Void)?

    private let port: SerialPort

    // Opcodes
    private enum Op: UInt8 {
        case nop = 0x00
        case indicate = 0x0D
        case read1 = 0x10
        case read2 = 0x11
        case read4 = 0x12
        case readFIFO = 0x18
        case write1 = 0x20
        case write2 = 0x21
        case write4 = 0x22
        case write8 = 0x23
        case writeFIFO = 0x28
    }

    // Register addresses
    private enum Reg {
        static let sweepStartHz: UInt8 = 0x00
        static let sweepStepHz: UInt8 = 0x10
        static let sweepPoints: UInt8 = 0x20
        static let valuesPerFrequency: UInt8 = 0x22
        static let rawSamplesMode: UInt8 = 0x26
        static let valuesFIFO: UInt8 = 0x30
        static let deviceVariant: UInt8 = 0xF0
        static let protocolVersion: UInt8 = 0xF1
        static let hardwareRevision: UInt8 = 0xF2
        static let firmwareMajor: UInt8 = 0xF3
        static let firmwareMinor: UInt8 = 0xF4
    }

    /// Number of averaged hardware samples the device takes per frequency point.
    public var valuesPerFrequency: UInt16 = 1

    public init(portPath: String, model: DeviceModel = DeviceCatalog.genericV2) {
        self.port = SerialPort(path: portPath)
        self.info = DeviceInfo(model: model, portPath: portPath)
    }

    // MARK: - Connection

    public func connect() throws {
        try port.open()
        log(.note, "Opened \(port.path)")
        // A run of NOPs resets any half-parsed command in the device.
        try port.write(Data(repeating: Op.nop.rawValue, count: 8))
        Thread.sleep(forTimeInterval: 0.05)
        port.flushAll()
        try identify()
    }

    public func disconnect() {
        port.close()
        log(.note, "Closed \(port.path)")
    }

    private func identify() throws {
        // `indicate` answers with the protocol generation, '2' for all V2 devices.
        try port.write(Data([Op.indicate.rawValue]))
        if let reply = try? port.readExactly(1, timeout: 1.0), let byte = reply.first {
            info.protocolVersion = "V\(Character(UnicodeScalar(byte)))"
        }

        let variant = (try? readRegister1(Reg.deviceVariant)) ?? 0
        let proto = (try? readRegister1(Reg.protocolVersion)) ?? 0
        let hw = (try? readRegister1(Reg.hardwareRevision)) ?? 0
        let major = (try? readRegister1(Reg.firmwareMajor)) ?? 0
        let minor = (try? readRegister1(Reg.firmwareMinor)) ?? 0

        info.model = DeviceIdentity.model(fromVariant: variant)
        info.screen = info.model.screen
        info.firmwareVersion = "\(major).\(minor)"
        info.hardwareRevision = String(format: "0x%02X", hw)
        info.protocolVersion = "\(proto)"
        info.banner = "Device variant 0x\(String(format: "%02X", variant)) · protocol \(proto) · hardware 0x\(String(format: "%02X", hw)) · firmware \(major).\(minor)"
        log(.note, "Identified as \(info.model.name) (\(info.banner))")
    }

    // MARK: - Register access

    private func readRegister1(_ address: UInt8) throws -> UInt8 {
        try port.write(Data([Op.read1.rawValue, address]))
        let data = try port.readExactly(1, timeout: 1.0)
        return data[data.startIndex]
    }

    private func readRegister2(_ address: UInt8) throws -> UInt16 {
        try port.write(Data([Op.read2.rawValue, address]))
        let data = try port.readExactly(2, timeout: 1.0)
        return UInt16(data[data.startIndex]) | (UInt16(data[data.startIndex + 1]) << 8)
    }

    private func writeRegister1(_ address: UInt8, _ value: UInt8) throws {
        try port.write(Data([Op.write1.rawValue, address, value]))
    }

    private func writeRegister2(_ address: UInt8, _ value: UInt16) throws {
        var bytes: [UInt8] = [Op.write2.rawValue, address]
        bytes.append(UInt8(value & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        try port.write(Data(bytes))
    }

    private func writeRegister8(_ address: UInt8, _ value: UInt64) throws {
        var bytes: [UInt8] = [Op.write8.rawValue, address]
        for shift in stride(from: 0, through: 56, by: 8) {
            bytes.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
        try port.write(Data(bytes))
    }

    private func clearFIFO() throws {
        try writeRegister1(Reg.valuesFIFO, 0)
    }

    // MARK: - Sweeping

    public func sweep(start: Double, stop: Double, points: Int) throws -> SweepFrame {
        guard port.isOpen else { throw DriverError.notConnected }
        let n = max(2, min(points, info.model.maxHardwarePoints))
        let startHz = UInt64(max(0, start.rounded()))
        let stepHz = n > 1 ? UInt64(((stop - start) / Double(n - 1)).rounded()) : 0

        try writeRegister8(Reg.sweepStartHz, startHz)
        try writeRegister8(Reg.sweepStepHz, stepHz)
        try writeRegister2(Reg.sweepPoints, UInt16(n))
        try writeRegister2(Reg.valuesPerFrequency, max(1, valuesPerFrequency))
        log(.sent, "sweep \(startHz) Hz step \(stepHz) Hz × \(n) points")

        port.flushInput()
        try clearFIFO()

        var frequencies = [Double](repeating: 0, count: n)
        for i in 0..<n { frequencies[i] = Double(startHz) + Double(stepHz) * Double(i) }
        var s11 = [Complex](repeating: .zero, count: n)
        var s21 = [Complex](repeating: .zero, count: n)
        var filled = [Bool](repeating: false, count: n)

        var remaining = n
        let deadline = Date().addingTimeInterval(max(10, Double(n) * 0.08 + 6))
        while remaining > 0 {
            guard Date() < deadline else {
                throw DriverError.protocolError("timed out after receiving \(n - remaining) of \(n) points")
            }
            let batch = UInt8(min(remaining, 255))
            try port.write(Data([Op.readFIFO.rawValue, Reg.valuesFIFO, batch]))
            let payload = try port.readExactly(Int(batch) * 32, timeout: 12)

            payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for k in 0..<Int(batch) {
                    let base = k * 32
                    let fwd = Complex(Double(int32(raw, base + 0)), Double(int32(raw, base + 4)))
                    let rev0 = Complex(Double(int32(raw, base + 8)), Double(int32(raw, base + 12)))
                    let rev1 = Complex(Double(int32(raw, base + 16)), Double(int32(raw, base + 20)))
                    let index = Int(UInt16(raw[base + 24]) | (UInt16(raw[base + 25]) << 8))
                    guard index < n else { continue }
                    if fwd.magnitudeSquared > 0 {
                        s11[index] = rev0 / fwd
                        s21[index] = rev1 / fwd
                    }
                    filled[index] = true
                }
            }
            remaining = filled.filter { !$0 }.count
        }

        log(.received, "\(n) points")
        return SweepFrame(frequencies: frequencies, s11: s11, s21: s21)
    }

    @inline(__always)
    private func int32(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> Int32 {
        let b0 = UInt32(raw[offset])
        let b1 = UInt32(raw[offset + 1]) << 8
        let b2 = UInt32(raw[offset + 2]) << 16
        let b3 = UInt32(raw[offset + 3]) << 24
        return Int32(bitPattern: b0 | b1 | b2 | b3)
    }

    // MARK: - Unsupported / trivial operations

    public func sendRaw(_ line: String, timeout: TimeInterval) throws -> String {
        throw DriverError.unsupported("text commands (this device uses the binary V2 protocol)")
    }

    public func captureScreen() throws -> ScreenCapture {
        throw DriverError.unsupported("screen capture over the V2 binary protocol")
    }

    public func readBattery() throws -> Int? { nil }
    public func pause() throws {}
    public func resume() throws {}

    private func log(_ direction: TrafficLogEntry.Direction, _ text: String) {
        trafficHandler?(TrafficLogEntry(direction: direction, text: text))
    }
}
