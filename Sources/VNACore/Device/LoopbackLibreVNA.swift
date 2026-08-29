import Foundation

/// An in-process LibreVNA that speaks the real packet protocol.
///
/// It exists for two reasons: it lets the driver be tested end to end without hardware,
/// and it gives the app a synthetic two-port instrument so the S12/S22 features and the
/// full two-port calibration can be explored with nothing plugged in.
public final class LoopbackLibreVNATransport: USBBulkTransport {

    public private(set) var isOpen = false

    /// Simulated device limits reported in the device-info packet.
    public var limits: LibreVNA.DeviceInfo = {
        var info = LibreVNA.DeviceInfo()
        info.protocolVersion = LibreVNA.protocolVersion
        info.firmwareMajor = 1
        info.firmwareMinor = 5
        info.firmwarePatch = 0
        info.hardwareVersion = 1
        info.hardwareRevision = "B"
        info.minFrequency = 100_000
        info.maxFrequency = 6_000_000_000
        info.minIFBandwidth = 10
        info.maxIFBandwidth = 50_000
        info.maxPoints = 4_501
        info.cdbmMin = -4_000
        info.cdbmMax = 0
        info.maxAmplitudePoints = 64
        info.maxFrequencyHarmonic = 18_000_000_000
        info.portCount = 2
        info.maxDwellTime = 1_000
        return info
    }()

    /// Noise added to each reading, in linear units.
    public var noiseFloor: Double = 0.0012
    /// Emulated per-sweep delay so the UI's live behaviour is realistic.
    public var sweepDelay: TimeInterval = 0.25

    private var inbox = Data()
    private var outbox = Data()
    private var noise = SyntheticDUT.Noise()
    private let lock = NSLock()

    public init() {}

    public func open() throws {
        lock.lock(); defer { lock.unlock() }
        isOpen = true
        inbox.removeAll()
        outbox.removeAll()
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        isOpen = false
        inbox.removeAll()
        outbox.removeAll()
    }

    public func write(_ data: Data, timeout: TimeInterval) throws {
        guard isOpen else { throw USBError.notOpen }
        lock.lock()
        inbox.append(data)
        let packets = LibreVNA.drain(&inbox)
        lock.unlock()
        for packet in packets { handle(packet) }
    }

    public func read(maxBytes: Int, timeout: TimeInterval) throws -> Data {
        guard isOpen else { throw USBError.notOpen }
        lock.lock(); defer { lock.unlock() }
        guard !outbox.isEmpty else { return Data() }
        let count = Swift.min(maxBytes, outbox.count)
        let chunk = outbox.prefix(count)
        outbox.removeFirst(count)
        return Data(chunk)
    }

    // MARK: - Device behaviour

    private func enqueue(_ packet: LibreVNA.Packet) {
        lock.lock(); defer { lock.unlock() }
        outbox.append(LibreVNA.encode(packet))
    }

    private func handle(_ packet: LibreVNA.Packet) {
        switch packet.type {
        case .requestDeviceInfo:
            enqueue(LibreVNA.Packet(type: .deviceInfo, payload: limits.encoded()))
        case .requestDeviceStatus:
            var status = LibreVNA.DeviceStatus()
            status.fpgaConfigured = true
            status.sourceLocked = true
            status.loLocked = true
            status.temperatureSource = 42
            status.temperatureLO = 45
            status.temperatureMCU = 38
            var payload = Data()
            var flags: UInt8 = 0
            if status.externalReferenceAvailable { flags |= 1 << 0 }
            if status.externalReferenceInUse { flags |= 1 << 1 }
            if status.fpgaConfigured { flags |= 1 << 2 }
            if status.sourceLocked { flags |= 1 << 3 }
            if status.loLocked { flags |= 1 << 4 }
            payload.append(flags)
            payload.append(UInt8(status.temperatureSource))
            payload.append(UInt8(status.temperatureLO))
            payload.append(UInt8(status.temperatureMCU))
            enqueue(LibreVNA.Packet(type: .deviceStatus, payload: payload))
        case .sweepSettings:
            guard let settings = LibreVNA.SweepSettings(payload: packet.payload) else {
                enqueue(LibreVNA.Packet(type: .nack))
                return
            }
            enqueue(LibreVNA.Packet(type: .ack))
            if sweepDelay > 0 { Thread.sleep(forTimeInterval: sweepDelay) }
            streamSweep(settings)
        case .setIdle, .stopStatusUpdates, .startStatusUpdates, .initiateSweep:
            enqueue(LibreVNA.Packet(type: .ack))
        default:
            break
        }
    }

    private func streamSweep(_ settings: LibreVNA.SweepSettings) {
        let n = Int(settings.points)
        guard n > 1 else { return }
        let start = Double(settings.startHz)
        let stop = Double(settings.stopHz)
        let twoPort = settings.stages >= 1

        for i in 0..<n {
            let t = Double(i) / Double(n - 1)
            let frequency = settings.logSweep && start > 0
                ? start * pow(stop / start, t)
                : start + (stop - start) * t

            var point = LibreVNA.Datapoint()
            point.frequency = UInt64(frequency.rounded())
            point.cdBm = settings.cdbmStart
            point.pointNumber = UInt16(i)

            // Stage 0: port 1 is excited.
            let reference = Complex(1, 0)
            point.add(SyntheticDUT.filterS11(at: frequency) + noise.complex(amplitude: noiseFloor),
                      stage: 0, port: 0, reference: false)
            point.add(SyntheticDUT.filterS21(at: frequency) + noise.complex(amplitude: noiseFloor),
                      stage: 0, port: 1, reference: false)
            point.add(reference, stage: 0, port: 0, reference: true)

            if twoPort {
                // Stage 1: port 2 is excited.
                point.add(SyntheticDUT.filterS12(at: frequency) + noise.complex(amplitude: noiseFloor),
                          stage: 1, port: 0, reference: false)
                point.add(SyntheticDUT.filterS22(at: frequency) + noise.complex(amplitude: noiseFloor),
                          stage: 1, port: 1, reference: false)
                point.add(reference, stage: 1, port: 1, reference: true)
            }

            enqueue(LibreVNA.Packet(type: .vnaDatapoint, payload: point.encoded()))
        }
    }
}

public extension LibreVNADriver {
    /// A driver backed by the in-process LibreVNA emulator.
    static func simulated() -> LibreVNADriver {
        var model = DeviceCatalog.libreVNA
        model.name = "LibreVNA Simulator"
        model.vendor = "Built-in"
        model.notes = "Synthetic two-port device: a 300 MHz bandpass filter measured in both "
                    + "directions, so S11, S21, S12 and S22 all carry real data."
        return LibreVNADriver(transport: LoopbackLibreVNATransport(),
                              portDescription: "librevna-simulator",
                              model: model)
    }
}
