import Foundation

/// Everything discovered about a connected analyser.
public struct DeviceInfo: Sendable, Equatable {
    public var model: DeviceModel
    public var portPath: String
    public var firmwareVersion: String = ""
    public var hardwareRevision: String = ""
    public var buildTime: String = ""
    public var protocolVersion: String = ""
    public var serialNumber: String = ""
    public var banner: String = ""
    /// Commands the firmware advertises in `help`.
    public var supportedCommands: Set<String> = []
    public var screen: ScreenSize?
    public var batteryMillivolts: Int?

    public init(model: DeviceModel, portPath: String) {
        self.model = model
        self.portPath = portPath
        self.screen = model.screen
    }

    public func supports(_ command: String) -> Bool {
        supportedCommands.isEmpty || supportedCommands.contains(command)
    }
}

/// A raw framebuffer grabbed from the instrument.
public struct ScreenCapture: Sendable {
    public var width: Int
    public var height: Int
    /// 8-bit RGBA, row major.
    public var rgba: [UInt8]
    public init(width: Int, height: Int, rgba: [UInt8]) {
        self.width = width
        self.height = height
        self.rgba = rgba
    }
}

public enum DriverError: LocalizedError {
    case notConnected
    case unsupported(String)
    case protocolError(String)
    case badResponse(String)
    case pointLimit(Int)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "No analyser is connected."
        case .unsupported(let what): return "This device does not support \(what)."
        case .protocolError(let d): return "Protocol error: \(d)"
        case .badResponse(let d): return "Unexpected response from the device: \(d)"
        case .pointLimit(let n): return "The device accepts at most \(n) points per sweep."
        }
    }
}

/// Log line emitted by a driver, surfaced in the console panel.
public struct TrafficLogEntry: Identifiable, Sendable {
    public enum Direction: Sendable { case sent, received, note, error }
    public let id = UUID()
    public let date: Date
    public let direction: Direction
    public let text: String
    public init(direction: Direction, text: String, date: Date = Date()) {
        self.direction = direction
        self.text = text
        self.date = date
    }
}

/// Blocking driver interface. Implementations are used from a single serial queue.
public protocol VNADriver: AnyObject {
    var info: DeviceInfo { get }
    var isConnected: Bool { get }
    /// Called with every byte exchanged, for the traffic console.
    var trafficHandler: ((TrafficLogEntry) -> Void)? { get set }

    func connect() throws
    func disconnect()

    /// Configure and run one sweep, returning uncorrected data.
    func sweep(start: Double, stop: Double, points: Int) throws -> SweepFrame

    /// Free-form command passthrough for the console (ASCII devices only).
    func sendRaw(_ line: String, timeout: TimeInterval) throws -> String

    func captureScreen() throws -> ScreenCapture
    func readBattery() throws -> Int?
    /// Stop any free-running sweep so the device is idle.
    func pause() throws
    func resume() throws
}

public extension VNADriver {
    func sendRaw(_ line: String) throws -> String { try sendRaw(line, timeout: 3) }
}

/// Convert an RGB565 big-endian framebuffer into RGBA8.
public func rgb565BigEndianToRGBA(_ data: Data, width: Int, height: Int) -> [UInt8] {
    var out = [UInt8](repeating: 255, count: width * height * 4)
    let pixels = min(width * height, data.count / 2)
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        for i in 0..<pixels {
            let hi = UInt16(raw[i * 2])
            let lo = UInt16(raw[i * 2 + 1])
            let v = (hi << 8) | lo
            let r = UInt8(((v >> 11) & 0x1F) * 255 / 31)
            let g = UInt8(((v >> 5) & 0x3F) * 255 / 63)
            let b = UInt8((v & 0x1F) * 255 / 31)
            out[i * 4 + 0] = r
            out[i * 4 + 1] = g
            out[i * 4 + 2] = b
            out[i * 4 + 3] = 255
        }
    }
    return out
}
