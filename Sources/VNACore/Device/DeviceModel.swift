import Foundation

/// Wire protocol spoken by a device.
public enum WireProtocol: String, Codable, CaseIterable, Sendable, Identifiable {
    case asciiShell     // NanoVNA / -H / -H4 / -F / -F V2 / tinySA text shell
    case binaryV2       // NanoVNA V2 (S-A-A-2), V2 Plus4, LiteVNA, SV series
    case libreVNA       // LibreVNA packet protocol over vendor-specific USB bulk endpoints
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .asciiShell: return "ASCII shell (text)"
        case .binaryV2: return "NanoVNA V2 binary"
        case .libreVNA: return "LibreVNA packet protocol"
        }
    }
    /// Devices reached over a serial port rather than raw USB.
    public var usesSerialPort: Bool { self != .libreVNA }
}

/// A screen resolution the device's `capture` command can return.
public struct ScreenSize: Codable, Hashable, Sendable {
    public var width: Int
    public var height: Int
    public init(_ w: Int, _ h: Int) { width = w; height = h }
    public var byteCount: Int { width * height * 2 }   // RGB565
    public var description: String { "\(width)×\(height)" }

    public static let known: [ScreenSize] = [
        ScreenSize(320, 240),
        ScreenSize(480, 320),
        ScreenSize(480, 272),
        ScreenSize(800, 480),
        ScreenSize(320, 480)
    ]

    public static func matching(byteCount: Int) -> ScreenSize? {
        known.first { $0.byteCount == byteCount }
    }
}

/// Static description of a supported hardware family.
public struct DeviceModel: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var vendor: String
    public var wireProtocol: WireProtocol
    public var minFrequency: Double
    public var maxFrequency: Double
    /// Highest frequency the fundamental (non-harmonic) path reaches, when relevant.
    public var fundamentalMax: Double?
    /// Points the hardware can sweep in one go.
    public var maxHardwarePoints: Int
    public var defaultPoints: Int
    public var screen: ScreenSize?
    public var supportsScreenshot: Bool
    public var supportsBattery: Bool
    /// True for instruments with a full reverse path (S12 and S22 are really measured).
    public var isFullTwoPort: Bool
    /// Number of test ports.
    public var portCount: Int
    public var notes: String

    public var frequencyRangeDescription: String {
        "\(Units.frequencyShort(minFrequency)) – \(Units.frequencyShort(maxFrequency))"
    }

    public init(id: String, name: String, vendor: String, wireProtocol: WireProtocol,
                minFrequency: Double, maxFrequency: Double, fundamentalMax: Double? = nil,
                maxHardwarePoints: Int, defaultPoints: Int, screen: ScreenSize?,
                supportsScreenshot: Bool = true, supportsBattery: Bool = true,
                isFullTwoPort: Bool = false, portCount: Int = 2, notes: String = "") {
        self.id = id
        self.name = name
        self.vendor = vendor
        self.wireProtocol = wireProtocol
        self.minFrequency = minFrequency
        self.maxFrequency = maxFrequency
        self.fundamentalMax = fundamentalMax
        self.maxHardwarePoints = maxHardwarePoints
        self.defaultPoints = defaultPoints
        self.screen = screen
        self.supportsScreenshot = supportsScreenshot
        self.supportsBattery = supportsBattery
        self.isFullTwoPort = isFullTwoPort
        self.portCount = portCount
        self.notes = notes
    }
}

public enum DeviceCatalog {

    public static let nanoVNA = DeviceModel(
        id: "nanovna", name: "NanoVNA (original)", vendor: "ttrftech / clones",
        wireProtocol: .asciiShell,
        minFrequency: 50_000, maxFrequency: 900e6, fundamentalMax: 300e6,
        maxHardwarePoints: 101, defaultPoints: 101, screen: ScreenSize(320, 240),
        notes: "Above 300 MHz the original firmware uses 3rd/5th harmonics with reduced dynamic range."
    )

    public static let nanoVNAH = DeviceModel(
        id: "nanovna-h", name: "NanoVNA-H", vendor: "Hugen",
        wireProtocol: .asciiShell,
        minFrequency: 10_000, maxFrequency: 1.5e9, fundamentalMax: 300e6,
        maxHardwarePoints: 401, defaultPoints: 201, screen: ScreenSize(320, 240),
        notes: "DiSlord firmware supports up to 401 points and segmented sweeps."
    )

    public static let nanoVNAH4 = DeviceModel(
        id: "nanovna-h4", name: "NanoVNA-H4", vendor: "Hugen",
        wireProtocol: .asciiShell,
        minFrequency: 10_000, maxFrequency: 1.5e9, fundamentalMax: 300e6,
        maxHardwarePoints: 401, defaultPoints: 201, screen: ScreenSize(480, 320),
        notes: "4 inch display, 480×320 screenshots."
    )

    public static let nanoVNAF = DeviceModel(
        id: "nanovna-f", name: "NanoVNA-F", vendor: "SYSJOINT",
        wireProtocol: .asciiShell,
        minFrequency: 10_000, maxFrequency: 1.5e9, fundamentalMax: 300e6,
        maxHardwarePoints: 301, defaultPoints: 201, screen: ScreenSize(480, 272),
        notes: "4.3 inch IPS, metal case, 5000 mAh battery."
    )

    public static let nanoVNAFV2 = DeviceModel(
        id: "nanovna-f-v2", name: "NanoVNA-F V2", vendor: "SYSJOINT",
        wireProtocol: .asciiShell,
        minFrequency: 50_000, maxFrequency: 3e9, fundamentalMax: 800e6,
        maxHardwarePoints: 301, defaultPoints: 201, screen: ScreenSize(800, 480),
        notes: "50 kHz – 3 GHz, 4.3 inch 800×480 IPS. Speaks the ASCII shell protocol; "
             + "sweeps above the fundamental limit use harmonic mixing."
    )

    public static let nanoVNAFV3 = DeviceModel(
        id: "nanovna-f-v3", name: "NanoVNA-F V3", vendor: "SYSJOINT",
        wireProtocol: .asciiShell,
        minFrequency: 50_000, maxFrequency: 6e9, fundamentalMax: 1.5e9,
        maxHardwarePoints: 301, defaultPoints: 201, screen: ScreenSize(800, 480),
        notes: "Extended 6 GHz range variant."
    )

    public static let nanoVNAV2 = DeviceModel(
        id: "nanovna-v2", name: "NanoVNA V2 (S-A-A-2)", vendor: "OwOComm / HCXQS",
        wireProtocol: .binaryV2,
        minFrequency: 50_000, maxFrequency: 3e9, fundamentalMax: 140e6,
        maxHardwarePoints: 1024, defaultPoints: 201, screen: ScreenSize(320, 240),
        notes: "True 3 GHz hardware, binary register protocol, no harmonic mixing above 140 MHz."
    )

    public static let nanoVNAV2Plus4 = DeviceModel(
        id: "nanovna-v2-plus4", name: "NanoVNA V2 Plus4", vendor: "HCXQS",
        wireProtocol: .binaryV2,
        minFrequency: 50_000, maxFrequency: 4.4e9, fundamentalMax: 140e6,
        maxHardwarePoints: 1024, defaultPoints: 201, screen: ScreenSize(480, 320),
        notes: "4.4 GHz variant with a 4 inch display."
    )

    public static let liteVNA62 = DeviceModel(
        id: "litevna-62", name: "LiteVNA 62", vendor: "zeenko",
        wireProtocol: .binaryV2,
        minFrequency: 50_000, maxFrequency: 6.3e9, fundamentalMax: 140e6,
        maxHardwarePoints: 1024, defaultPoints: 201, screen: ScreenSize(320, 240),
        notes: "2.8 inch LiteVNA, V2 protocol."
    )

    public static let liteVNA64 = DeviceModel(
        id: "litevna-64", name: "LiteVNA 64", vendor: "zeenko",
        wireProtocol: .binaryV2,
        minFrequency: 50_000, maxFrequency: 6.3e9, fundamentalMax: 140e6,
        maxHardwarePoints: 1024, defaultPoints: 201, screen: ScreenSize(480, 320),
        notes: "4 inch LiteVNA, V2 protocol."
    )

    public static let sv4401a = DeviceModel(
        id: "sv4401a", name: "SV4401A", vendor: "SYSJOINT",
        wireProtocol: .binaryV2,
        minFrequency: 50_000, maxFrequency: 4.4e9, fundamentalMax: 140e6,
        maxHardwarePoints: 1024, defaultPoints: 201, screen: ScreenSize(800, 480),
        notes: "7 inch V2-protocol analyser."
    )

    public static let sv6301a = DeviceModel(
        id: "sv6301a", name: "SV6301A", vendor: "SYSJOINT",
        wireProtocol: .binaryV2,
        minFrequency: 50_000, maxFrequency: 6.3e9, fundamentalMax: 140e6,
        maxHardwarePoints: 1024, defaultPoints: 201, screen: ScreenSize(800, 480),
        notes: "7 inch 6.3 GHz V2-protocol analyser."
    )

    public static let nanoVNAV2Plus = DeviceModel(
        id: "nanovna-v2-plus", name: "NanoVNA V2 Plus", vendor: "HCXQS",
        wireProtocol: .binaryV2,
        minFrequency: 50_000, maxFrequency: 3e9, fundamentalMax: 140e6,
        maxHardwarePoints: 1024, defaultPoints: 201, screen: ScreenSize(320, 240),
        notes: "2.8 inch V2 Plus, same 3 GHz hardware as the S-A-A-2 with more memory."
    )

    public static let saa2n = DeviceModel(
        id: "saa-2n", name: "SAA-2N (NanoVNA V2)", vendor: "NanoRFE / clones",
        wireProtocol: .binaryV2,
        minFrequency: 50_000, maxFrequency: 3e9, fundamentalMax: 140e6,
        maxHardwarePoints: 1024, defaultPoints: 201, screen: ScreenSize(320, 240),
        notes: "V2 hardware in a metal case, sold as SAA-2N."
    )

    public static let deepVNA101 = DeviceModel(
        id: "deepvna-101", name: "DeepVNA 101", vendor: "Deepelec",
        wireProtocol: .asciiShell,
        minFrequency: 10_000, maxFrequency: 1.5e9, fundamentalMax: 300e6,
        maxHardwarePoints: 301, defaultPoints: 201, screen: ScreenSize(480, 320),
        notes: "NanoVNA-H4 derivative with the same text shell."
    )

    public static let libreVNA = DeviceModel(
        id: "librevna", name: "LibreVNA", vendor: "Jan Käberich",
        wireProtocol: .libreVNA,
        minFrequency: 100_000, maxFrequency: 6e9, fundamentalMax: nil,
        maxHardwarePoints: 4501, defaultPoints: 501, screen: nil,
        supportsScreenshot: false, supportsBattery: false,
        isFullTwoPort: true, portCount: 2,
        notes: "Open-source 100 kHz – 6 GHz two-port analyser. Measures S11, S21, S12 and S22 in one "
             + "sweep, so it supports a full 12-term two-port calibration. Connects over a "
             + "vendor-specific USB interface rather than a serial port."
    )

    public static let libreVNAGeneric = DeviceModel(
        id: "librevna-generic", name: "LibreVNA (unrecognised revision)", vendor: "Jan Käberich",
        wireProtocol: .libreVNA,
        minFrequency: 100_000, maxFrequency: 6e9, fundamentalMax: nil,
        maxHardwarePoints: 4501, defaultPoints: 501, screen: nil,
        supportsScreenshot: false, supportsBattery: false,
        isFullTwoPort: true, portCount: 2,
        notes: "Limits are read from the device itself once connected."
    )

    public static let genericASCII = DeviceModel(
        id: "generic-ascii", name: "Generic NanoVNA (ASCII)", vendor: "Unknown",
        wireProtocol: .asciiShell,
        minFrequency: 10_000, maxFrequency: 1.5e9, fundamentalMax: nil,
        maxHardwarePoints: 101, defaultPoints: 101, screen: nil,
        notes: "Identified by the text shell but not matched to a known model. Limits are conservative."
    )

    public static let genericV2 = DeviceModel(
        id: "generic-v2", name: "Generic V2-protocol VNA", vendor: "Unknown",
        wireProtocol: .binaryV2,
        minFrequency: 50_000, maxFrequency: 3e9, fundamentalMax: nil,
        maxHardwarePoints: 1024, defaultPoints: 201, screen: nil,
        notes: "Speaks the V2 binary protocol but reports an unknown device variant."
    )

    public static let all: [DeviceModel] = [
        nanoVNA, nanoVNAH, nanoVNAH4, nanoVNAF, nanoVNAFV2, nanoVNAFV3, deepVNA101,
        nanoVNAV2, nanoVNAV2Plus, nanoVNAV2Plus4, saa2n, liteVNA62, liteVNA64, sv4401a, sv6301a,
        libreVNA, libreVNAGeneric,
        genericASCII, genericV2
    ]

    public static func model(id: String) -> DeviceModel? { all.first { $0.id == id } }
}

/// Runtime identification: matching a connected device to a catalogue entry.
public enum DeviceIdentity {

    /// Known USB vendor/product pairs seen on these analysers.
    public static func likelihoodScore(for port: SerialPortInfo) -> Int {
        var score = 0
        let name = (port.usbProductName ?? "").lowercased()
        if name.contains("nanovna") || name.contains("vna") { score += 100 }
        if name.contains("litevna") || name.contains("saa") { score += 100 }
        if port.path.lowercased().contains("usbmodem") { score += 20 }
        if port.path.lowercased().contains("usbserial") { score += 10 }
        // STMicroelectronics Virtual COM Port — used by most NanoVNA builds.
        if port.vendorID == 0x0483 && port.productID == 0x5740 { score += 60 }
        // NanoVNA V2 reference firmware.
        if port.vendorID == 0x04B4 && port.productID == 0x0008 { score += 60 }
        // Some F-series units enumerate as a WCH or CH340 bridge.
        if port.vendorID == 0x1A86 { score += 25 }
        if port.vendorID == 0x0403 { score += 15 }
        return score
    }

    /// Match a firmware banner (from `version` / `info`) to a catalogue entry.
    public static func model(fromBanner banner: String) -> DeviceModel? {
        let text = banner.lowercased()
        if text.contains("nanovna-f_v3") || text.contains("nanovna-f v3") || text.contains("f_v3") {
            return DeviceCatalog.nanoVNAFV3
        }
        if text.contains("nanovna-f_v2") || text.contains("nanovna-f v2") || text.contains("f_v2") {
            return DeviceCatalog.nanoVNAFV2
        }
        if text.contains("nanovna-f") || text.contains("nanovna_f") { return DeviceCatalog.nanoVNAF }
        if text.contains("h4") { return DeviceCatalog.nanoVNAH4 }
        if text.contains("nanovna-h") || text.contains("nanovna_h") { return DeviceCatalog.nanoVNAH }
        if text.contains("litevna") { return DeviceCatalog.liteVNA64 }
        if text.contains("sv6301") { return DeviceCatalog.sv6301a }
        if text.contains("sv4401") { return DeviceCatalog.sv4401a }
        if text.contains("librevna") { return DeviceCatalog.libreVNA }
        if text.contains("deepvna") { return DeviceCatalog.deepVNA101 }
        if text.contains("saa-2n") || text.contains("saa2n") { return DeviceCatalog.saa2n }
        if text.contains("nanovna") { return DeviceCatalog.nanoVNA }
        return nil
    }

    /// Map the V2 `deviceVariant` register to a catalogue entry.
    public static func model(fromVariant variant: UInt8) -> DeviceModel {
        switch variant {
        case 0x02: return DeviceCatalog.nanoVNAV2
        case 0x03: return DeviceCatalog.nanoVNAV2Plus
        case 0x04: return DeviceCatalog.nanoVNAV2Plus4
        case 0x06: return DeviceCatalog.liteVNA62
        case 0x0A: return DeviceCatalog.liteVNA64
        case 0x40: return DeviceCatalog.sv4401a
        case 0x63: return DeviceCatalog.sv6301a
        default: return DeviceCatalog.genericV2
        }
    }
}
