import Foundation

/// Wire protocol of the LibreVNA (jankae/LibreVNA), protocol version 14.
///
/// Every packet is:
///
///     [0x5A][uint16 total length][uint8 type][payload…][uint32 CRC32]
///
/// where the length includes the header and the CRC, and the CRC is computed over
/// everything before it. Datapoint packets carry a zero CRC — the firmware skips the
/// calculation there because it dominates the per-point transmit cost.
public enum LibreVNA {

    public static let headerByte: UInt8 = 0x5A
    public static let headerLength = 4          // sync + length + type
    public static let crcLength = 4
    public static let overheadLength = 8
    public static let protocolVersion: UInt16 = 14

    public enum PacketType: UInt8, Sendable {
        case none = 0
        case sweepSettings = 2
        case manualStatus = 3
        case manualControl = 4
        case deviceInfo = 5
        case firmwarePacket = 6
        case ack = 7
        case clearFlash = 8
        case performFirmwareUpdate = 9
        case nack = 10
        case reference = 11
        case generator = 12
        case spectrumAnalyzerSettings = 13
        case spectrumAnalyzerResult = 14
        case requestDeviceInfo = 15
        case requestSourceCal = 16
        case requestReceiverCal = 17
        case sourceCalPoint = 18
        case receiverCalPoint = 19
        case setIdle = 20
        case requestFrequencyCorrection = 21
        case frequencyCorrection = 22
        case requestDeviceConfiguration = 23
        case deviceConfiguration = 24
        case deviceStatus = 25
        case requestDeviceStatus = 26
        case vnaDatapoint = 27
        case setTrigger = 28
        case clearTrigger = 29
        case stopStatusUpdates = 30
        case startStatusUpdates = 31
        case initiateSweep = 32
        case performAction = 33
        case resetDeviceConfiguration = 34
    }

    public struct Packet: Sendable, Equatable {
        public var type: PacketType
        public var payload: Data
        public init(type: PacketType, payload: Data = Data()) {
            self.type = type
            self.payload = payload
        }
    }

    // MARK: - CRC

    /// CRC-32/ISO-HDLC, matching the firmware's implementation.
    public static func crc32(_ bytes: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return ~crc
    }

    // MARK: - Framing

    public static func encode(_ packet: Packet) -> Data {
        let total = overheadLength + packet.payload.count
        var out = Data(capacity: total)
        out.append(headerByte)
        out.appendLittleEndian(UInt16(total))
        out.append(packet.type.rawValue)
        out.append(packet.payload)
        // The firmware zeroes the CRC on datapoints; mirror that so a loopback round-trips.
        let crc = packet.type == .vnaDatapoint ? 0 : crc32(out)
        out.appendLittleEndian(crc)
        return out
    }

    public enum DecodeOutcome: Equatable {
        /// A complete packet was consumed; `consumed` bytes should be dropped.
        case packet(Packet, consumed: Int)
        /// Not enough bytes yet; keep buffering.
        case incomplete
        /// The leading bytes are unusable; drop `consumed` bytes and retry.
        case resync(consumed: Int)
    }

    /// Pull one packet off the front of a receive buffer.
    public static func decodeOne(_ buffer: Data) -> DecodeOutcome {
        guard !buffer.isEmpty else { return .incomplete }
        let bytes = [UInt8](buffer)

        // Skip anything before the sync byte.
        guard let sync = bytes.firstIndex(of: headerByte) else {
            return .resync(consumed: bytes.count)
        }
        if sync > 0 { return .resync(consumed: sync) }
        guard bytes.count >= headerLength else { return .incomplete }

        let length = Int(UInt16(bytes[1]) | (UInt16(bytes[2]) << 8))
        guard length >= overheadLength else { return .resync(consumed: 1) }
        guard bytes.count >= length else { return .incomplete }

        let frame = Data(bytes[0..<length])
        let received = UInt32(bytes[length - 4])
            | (UInt32(bytes[length - 3]) << 8)
            | (UInt32(bytes[length - 2]) << 16)
            | (UInt32(bytes[length - 1]) << 24)

        guard let type = PacketType(rawValue: bytes[3]) else { return .resync(consumed: 1) }

        if type == .vnaDatapoint {
            // Datapoints intentionally carry a zero CRC.
            guard received == 0 else { return .resync(consumed: 1) }
        } else {
            let expected = crc32(frame.prefix(length - crcLength))
            guard received == expected else { return .resync(consumed: 1) }
        }

        let payload = Data(bytes[headerLength..<(length - crcLength)])
        return .packet(Packet(type: type, payload: payload), consumed: length)
    }

    /// Drain every complete packet from a buffer, leaving the remainder in place.
    public static func drain(_ buffer: inout Data) -> [Packet] {
        var packets: [Packet] = []
        var guardCounter = 0
        while !buffer.isEmpty {
            guardCounter += 1
            if guardCounter > 100_000 { break }
            switch decodeOne(buffer) {
            case .packet(let packet, let consumed):
                packets.append(packet)
                buffer.removeFirst(consumed)
            case .resync(let consumed):
                buffer.removeFirst(min(consumed, buffer.count))
            case .incomplete:
                return packets
            }
        }
        return packets
    }

    // MARK: - Sweep settings (31 bytes, packed)

    public struct SweepSettings: Sendable, Equatable {
        public var startHz: UInt64 = 1_000_000
        public var stopHz: UInt64 = 6_000_000_000
        public var points: UInt16 = 201
        public var ifBandwidth: UInt32 = 1_000
        /// Excitation power in 1/100 dBm.
        public var cdbmStart: Int16 = -1_000
        public var cdbmStop: Int16 = -1_000
        public var standby = false
        public var syncMaster = false
        public var suppressPeaks = true
        public var fixedPowerSetting = true
        public var logSweep = false
        /// 0 = none, 1 = USB, 2 = external reference, 3 = trigger.
        public var syncMode: UInt8 = 0
        /// Number of excitation stages minus one (1 for a two-port forward+reverse sweep).
        public var stages: UInt16 = 1
        public var port1Stage: UInt16 = 0
        public var port2Stage: UInt16 = 1
        public var port3Stage: UInt16 = 0
        public var port4Stage: UInt16 = 0
        public var dwellTimeMicroseconds: UInt16 = 0

        public init() {}

        public func encoded() -> Data {
            var data = Data(capacity: 31)
            data.appendLittleEndian(startHz)
            data.appendLittleEndian(stopHz)
            data.appendLittleEndian(points)
            data.appendLittleEndian(ifBandwidth)
            data.appendLittleEndian(cdbmStart)

            var flags: UInt8 = 0
            if standby { flags |= 1 << 0 }
            if syncMaster { flags |= 1 << 1 }
            if suppressPeaks { flags |= 1 << 2 }
            if fixedPowerSetting { flags |= 1 << 3 }
            if logSweep { flags |= 1 << 4 }
            flags |= (syncMode & 0x03) << 5
            data.append(flags)

            // Five 3-bit fields packed from the least significant bit upwards.
            var stageWord: UInt16 = 0
            stageWord |= (stages & 0x07)
            stageWord |= (port1Stage & 0x07) << 3
            stageWord |= (port2Stage & 0x07) << 6
            stageWord |= (port3Stage & 0x07) << 9
            stageWord |= (port4Stage & 0x07) << 12
            data.appendLittleEndian(stageWord)

            data.appendLittleEndian(cdbmStop)
            data.appendLittleEndian(dwellTimeMicroseconds)
            return data
        }

        public static let encodedSize = 31

        public init?(payload: Data) {
            guard payload.count >= Self.encodedSize else { return nil }
            let b = [UInt8](payload)
            startHz = b.littleEndian(UInt64.self, at: 0)
            stopHz = b.littleEndian(UInt64.self, at: 8)
            points = b.littleEndian(UInt16.self, at: 16)
            ifBandwidth = b.littleEndian(UInt32.self, at: 18)
            cdbmStart = Int16(bitPattern: b.littleEndian(UInt16.self, at: 22))

            let flags = b[24]
            standby = flags & (1 << 0) != 0
            syncMaster = flags & (1 << 1) != 0
            suppressPeaks = flags & (1 << 2) != 0
            fixedPowerSetting = flags & (1 << 3) != 0
            logSweep = flags & (1 << 4) != 0
            syncMode = (flags >> 5) & 0x03

            let stageWord = b.littleEndian(UInt16.self, at: 25)
            stages = stageWord & 0x07
            port1Stage = (stageWord >> 3) & 0x07
            port2Stage = (stageWord >> 6) & 0x07
            port3Stage = (stageWord >> 9) & 0x07
            port4Stage = (stageWord >> 12) & 0x07

            cdbmStop = Int16(bitPattern: b.littleEndian(UInt16.self, at: 27))
            dwellTimeMicroseconds = b.littleEndian(UInt16.self, at: 29)
        }
    }

    // MARK: - Device info (57 bytes, packed)

    public struct DeviceInfo: Sendable, Equatable {
        public var protocolVersion: UInt16 = 0
        public var firmwareMajor: UInt8 = 0
        public var firmwareMinor: UInt8 = 0
        public var firmwarePatch: UInt8 = 0
        public var hardwareVersion: UInt8 = 0
        public var hardwareRevision: Character = " "
        public var minFrequency: UInt64 = 0
        public var maxFrequency: UInt64 = 0
        public var minIFBandwidth: UInt32 = 0
        public var maxIFBandwidth: UInt32 = 0
        public var maxPoints: UInt16 = 0
        public var cdbmMin: Int16 = 0
        public var cdbmMax: Int16 = 0
        public var minRBW: UInt32 = 0
        public var maxRBW: UInt32 = 0
        public var maxAmplitudePoints: UInt8 = 0
        public var maxFrequencyHarmonic: UInt64 = 0
        public var portCount: UInt8 = 2
        public var maxDwellTime: UInt16 = 0

        public static let encodedSize = 57

        public init() {}

        public init?(payload: Data) {
            guard payload.count >= Self.encodedSize else { return nil }
            let b = [UInt8](payload)
            var o = 0
            func u16() -> UInt16 { defer { o += 2 }; return b.littleEndian(UInt16.self, at: o) }
            func u32() -> UInt32 { defer { o += 4 }; return b.littleEndian(UInt32.self, at: o) }
            func u64() -> UInt64 { defer { o += 8 }; return b.littleEndian(UInt64.self, at: o) }
            func u8() -> UInt8 { defer { o += 1 }; return b[o] }
            func i16() -> Int16 { Int16(bitPattern: u16()) }

            protocolVersion = u16()
            firmwareMajor = u8()
            firmwareMinor = u8()
            firmwarePatch = u8()
            hardwareVersion = u8()
            hardwareRevision = Character(UnicodeScalar(u8()))
            minFrequency = u64()
            maxFrequency = u64()
            minIFBandwidth = u32()
            maxIFBandwidth = u32()
            maxPoints = u16()
            cdbmMin = i16()
            cdbmMax = i16()
            minRBW = u32()
            maxRBW = u32()
            maxAmplitudePoints = u8()
            maxFrequencyHarmonic = u64()
            portCount = u8()
            maxDwellTime = u16()
        }

        /// Encode, used by the tests and the loopback transport.
        public func encoded() -> Data {
            var d = Data(capacity: Self.encodedSize)
            d.appendLittleEndian(protocolVersion)
            d.append(firmwareMajor); d.append(firmwareMinor); d.append(firmwarePatch)
            d.append(hardwareVersion)
            d.append(hardwareRevision.asciiValue ?? 0x20)
            d.appendLittleEndian(minFrequency)
            d.appendLittleEndian(maxFrequency)
            d.appendLittleEndian(minIFBandwidth)
            d.appendLittleEndian(maxIFBandwidth)
            d.appendLittleEndian(maxPoints)
            d.appendLittleEndian(cdbmMin)
            d.appendLittleEndian(cdbmMax)
            d.appendLittleEndian(minRBW)
            d.appendLittleEndian(maxRBW)
            d.append(maxAmplitudePoints)
            d.appendLittleEndian(maxFrequencyHarmonic)
            d.append(portCount)
            d.appendLittleEndian(maxDwellTime)
            return d
        }

        public var firmwareDescription: String {
            "\(firmwareMajor).\(firmwareMinor).\(firmwarePatch)"
        }
    }

    // MARK: - VNA datapoint

    /// One sweep point. The device sends every receiver reading it took, tagged with the
    /// excitation stage, which receiver it came from, and whether it is a reference channel.
    public struct Datapoint: Sendable {
        public var frequency: UInt64 = 0
        /// Excitation level in 1/100 dBm.
        public var cdBm: Int16 = 0
        public var pointNumber: UInt16 = 0
        public var real: [Float] = []
        public var imaginary: [Float] = []
        public var descriptors: [UInt8] = []

        public static let referenceBit: UInt8 = 0x10
        public static let stageShift: UInt8 = 5

        public init() {}

        public init?(payload: Data) {
            let headerSize = 12
            guard payload.count >= headerSize else { return nil }
            let valueCount = (payload.count - headerSize) / 9
            guard valueCount >= 0 else { return nil }
            let b = [UInt8](payload)

            frequency = b.littleEndian(UInt64.self, at: 0)
            cdBm = Int16(bitPattern: b.littleEndian(UInt16.self, at: 8))
            pointNumber = b.littleEndian(UInt16.self, at: 10)

            var o = headerSize
            real = (0..<valueCount).map { _ -> Float in
                defer { o += 4 }
                return Float(bitPattern: b.littleEndian(UInt32.self, at: o))
            }
            imaginary = (0..<valueCount).map { _ -> Float in
                defer { o += 4 }
                return Float(bitPattern: b.littleEndian(UInt32.self, at: o))
            }
            descriptors = (0..<valueCount).map { _ -> UInt8 in
                defer { o += 1 }
                return b[o]
            }
        }

        public func encoded() -> Data {
            var d = Data()
            d.appendLittleEndian(frequency)
            d.appendLittleEndian(UInt16(bitPattern: cdBm))
            d.appendLittleEndian(pointNumber)
            for v in real { d.appendLittleEndian(v.bitPattern) }
            for v in imaginary { d.appendLittleEndian(v.bitPattern) }
            for v in descriptors { d.append(v) }
            return d
        }

        public mutating func add(_ value: Complex, stage: UInt8, port: Int, reference: Bool) {
            real.append(Float(value.re))
            imaginary.append(Float(value.im))
            var descriptor: UInt8 = 1 << UInt8(port)
            if reference { descriptor |= Self.referenceBit }
            descriptor |= stage << Self.stageShift
            descriptors.append(descriptor)
        }

        /// Reading from one receiver during one excitation stage.
        /// `port` is zero-based. Returns nil when the device did not send that reading.
        public func value(stage: UInt8, port: Int, reference: Bool) -> Complex? {
            let portBit = UInt8(1) << UInt8(port)
            for i in descriptors.indices {
                let d = descriptors[i]
                guard (d >> Self.stageShift) == stage else { continue }
                guard (d & portBit) == portBit else { continue }
                guard ((d & Self.referenceBit) != 0) == reference else { continue }
                return Complex(Double(real[i]), Double(imaginary[i]))
            }
            return nil
        }

        /// S-parameter S(receivePort, excitePort), both 1-based, given the stage each port was excited on.
        public func sParameter(receivePort: Int, excitePort: Int, stage: UInt8) -> Complex? {
            guard let reference = value(stage: stage, port: excitePort - 1, reference: true),
                  let received = value(stage: stage, port: receivePort - 1, reference: false),
                  reference.magnitudeSquared > 0
            else { return nil }
            return received / reference
        }
    }

    // MARK: - Reference settings

    public struct ReferenceSettings: Sendable, Equatable {
        public var externalOutputFrequency: UInt32 = 0
        public var automaticSwitch = true
        public var useExternalReference = false
        public init() {}

        public func encoded() -> Data {
            var d = Data()
            d.appendLittleEndian(externalOutputFrequency)
            var flags: UInt8 = 0
            if automaticSwitch { flags |= 1 << 0 }
            if useExternalReference { flags |= 1 << 1 }
            d.append(flags)
            return d
        }
    }

    /// Status flags as reported by LibreVNA V1 hardware.
    public struct DeviceStatus: Sendable, Equatable {
        public var externalReferenceAvailable = false
        public var externalReferenceInUse = false
        public var fpgaConfigured = false
        public var sourceLocked = false
        public var loLocked = false
        public var adcOverload = false
        public var unlevel = false
        public var temperatureSource: Int = 0
        public var temperatureLO: Int = 0
        public var temperatureMCU: Int = 0

        public init() {}

        public init?(payload: Data) {
            guard payload.count >= 4 else { return nil }
            let b = [UInt8](payload)
            let flags = b[0]
            externalReferenceAvailable = flags & (1 << 0) != 0
            externalReferenceInUse = flags & (1 << 1) != 0
            fpgaConfigured = flags & (1 << 2) != 0
            sourceLocked = flags & (1 << 3) != 0
            loLocked = flags & (1 << 4) != 0
            adcOverload = flags & (1 << 5) != 0
            unlevel = flags & (1 << 6) != 0
            temperatureSource = Int(b[1])
            temperatureLO = Int(b[2])
            temperatureMCU = Int(b[3])
        }

        public var summary: String {
            var parts: [String] = []
            if !sourceLocked { parts.append("source unlocked") }
            if !loLocked { parts.append("LO unlocked") }
            if adcOverload { parts.append("ADC overload") }
            if unlevel { parts.append("unlevelled") }
            if externalReferenceInUse { parts.append("external reference") }
            return parts.isEmpty ? "OK" : parts.joined(separator: ", ")
        }
    }
}

// MARK: - Little-endian helpers

extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

extension Array where Element == UInt8 {
    func littleEndian<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        let size = MemoryLayout<T>.size
        guard offset >= 0, offset + size <= count else { return 0 }
        var value: T = 0
        for i in 0..<size {
            value |= T(truncatingIfNeeded: Int(self[offset + i])) << T(8 * i)
        }
        return value
    }
}
