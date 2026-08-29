import Foundation
import IOKit
import IOKit.usb
import IOKit.usb.IOUSBLib

/// A USB device discovered on the bus, for instruments that do not present a serial port.
public struct USBDeviceInfo: Identifiable, Hashable, Sendable {
    public var vendorID: Int
    public var productID: Int
    public var productName: String?
    public var vendorName: String?
    public var serialNumber: String?
    public var locationID: Int

    public var id: String { String(format: "usb:%04X:%04X:%08X", vendorID, productID, locationID) }

    public var displayName: String {
        productName ?? String(format: "USB device %04X:%04X", vendorID, productID)
    }

    public var identifierString: String { String(format: "%04X:%04X", vendorID, productID) }

    public init(vendorID: Int, productID: Int, productName: String? = nil, vendorName: String? = nil,
                serialNumber: String? = nil, locationID: Int = 0) {
        self.vendorID = vendorID
        self.productID = productID
        self.productName = productName
        self.vendorName = vendorName
        self.serialNumber = serialNumber
        self.locationID = locationID
    }
}

public enum USBError: LocalizedError {
    case notFound
    case openFailed(String, kern_return_t)
    case noMatchingInterface
    case pipeNotFound(UInt8)
    case transferFailed(String, kern_return_t)
    case notOpen
    case timeout

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "The USB device is no longer connected."
        case .openFailed(let stage, let code):
            return "Could not open the USB device (\(stage), 0x\(String(code, radix: 16))). "
                 + "Another application may already be using it — close the LibreVNA GUI and try again."
        case .noMatchingInterface:
            return "The device does not expose the expected USB interface."
        case .pipeNotFound(let endpoint):
            return String(format: "USB endpoint 0x%02X was not found on the device.", endpoint)
        case .transferFailed(let stage, let code):
            return "USB transfer failed (\(stage), 0x\(String(code, radix: 16)))."
        case .notOpen:
            return "The USB device is not open."
        case .timeout:
            return "The USB device did not respond in time."
        }
    }
}

/// IOKit USB return codes that the SDK only exposes as C macros.
private enum USBReturn {
    /// `iokit_usb_err(0x4f)` — the endpoint returned a STALL and must be cleared.
    static let pipeStalled: IOReturn = -536_854_449      // 0xE000404F
    /// `iokit_usb_err(0x51)` — the transaction timed out.
    static let transactionTimeout: IOReturn = -536_854_447 // 0xE0004051
}

/// Bulk-endpoint transport, so the driver can be exercised with a loopback in tests.
public protocol USBBulkTransport: AnyObject {
    var isOpen: Bool { get }
    func open() throws
    func close()
    func write(_ data: Data, timeout: TimeInterval) throws
    /// Returns whatever is available, or empty on timeout.
    func read(maxBytes: Int, timeout: TimeInterval) throws -> Data
}

// MARK: - IOKit implementation

/// Bulk USB transport built on IOUSBLib, the same user-space interface libusb uses on macOS.
public final class IOKitUSBBulkDevice: USBBulkTransport {

    private typealias DeviceInterface = IOUSBDeviceInterface500
    private typealias InterfaceInterface = IOUSBInterfaceInterface500

    private let info: USBDeviceInfo
    private let outEndpoint: UInt8
    private let inEndpoint: UInt8

    private var device: UnsafeMutablePointer<UnsafeMutablePointer<DeviceInterface>?>?
    private var interface: UnsafeMutablePointer<UnsafeMutablePointer<InterfaceInterface>?>?
    private var outPipe: UInt8 = 0
    private var inPipe: UInt8 = 0

    public var isOpen: Bool { interface != nil }

    public init(info: USBDeviceInfo, outEndpoint: UInt8, inEndpoint: UInt8) {
        self.info = info
        self.outEndpoint = outEndpoint
        self.inEndpoint = inEndpoint
    }

    deinit { close() }

    // MARK: UUIDs

    private static func uuid(_ b: [UInt8]) -> CFUUID {
        CFUUIDGetConstantUUIDWithBytes(nil, b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                                       b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
    }
    private static let plugInInterfaceID = uuid([0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
                                                 0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F])
    private static let deviceUserClientTypeID = uuid([0x9D, 0xC7, 0xB7, 0x80, 0x9E, 0xC0, 0x11, 0xD4,
                                                      0xA5, 0x4F, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61])
    private static let deviceInterfaceID500 = uuid([0xA3, 0x3C, 0xF0, 0x47, 0x4B, 0x5B, 0x48, 0xE2,
                                                    0xB5, 0x7D, 0x02, 0x07, 0xFC, 0xEA, 0xE1, 0x3B])
    private static let interfaceUserClientTypeID = uuid([0x2D, 0x97, 0x86, 0xC6, 0x9E, 0xF3, 0x11, 0xD4,
                                                         0xAD, 0x51, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61])
    private static let interfaceInterfaceID500 = uuid([0x6C, 0x0D, 0x38, 0xC3, 0xB0, 0x93, 0x4E, 0xA7,
                                                       0x80, 0x9B, 0x09, 0xFB, 0x5D, 0xDD, 0xAC, 0x16])

    // MARK: Open / close

    public func open() throws {
        guard interface == nil else { return }
        guard let service = Self.findService(matching: info) else { throw USBError.notFound }
        defer { IOObjectRelease(service) }

        guard let dev = Self.queryInterface(service: service,
                                            typeID: Self.deviceUserClientTypeID,
                                            interfaceID: Self.deviceInterfaceID500,
                                            as: DeviceInterface.self)
        else { throw USBError.openFailed("device interface", KERN_FAILURE) }
        device = dev

        var result = dev.pointee!.pointee.USBDeviceOpen(dev)
        if result != kIOReturnSuccess {
            // Fall back to a seized open: another process may hold a non-exclusive handle.
            result = dev.pointee!.pointee.USBDeviceOpenSeize(dev)
        }
        guard result == kIOReturnSuccess else {
            releaseDevice()
            throw USBError.openFailed("USBDeviceOpen", result)
        }

        // Configure the device if the system has not already done so.
        var configuration: UInt8 = 0
        _ = dev.pointee!.pointee.GetConfiguration(dev, &configuration)
        if configuration == 0 {
            var descriptor: UnsafeMutablePointer<IOUSBConfigurationDescriptor>?
            if dev.pointee!.pointee.GetConfigurationDescriptorPtr(dev, 0, &descriptor) == kIOReturnSuccess,
               let value = descriptor?.pointee.bConfigurationValue {
                _ = dev.pointee!.pointee.SetConfiguration(dev, value)
            } else {
                _ = dev.pointee!.pointee.SetConfiguration(dev, 1)
            }
        }

        try openInterface(on: dev)
    }

    private func openInterface(on dev: UnsafeMutablePointer<UnsafeMutablePointer<DeviceInterface>?>) throws {
        var request = IOUSBFindInterfaceRequest(
            bInterfaceClass: UInt16(kIOUSBFindInterfaceDontCare),
            bInterfaceSubClass: UInt16(kIOUSBFindInterfaceDontCare),
            bInterfaceProtocol: UInt16(kIOUSBFindInterfaceDontCare),
            bAlternateSetting: UInt16(kIOUSBFindInterfaceDontCare))

        var iterator: io_iterator_t = 0
        let kr = dev.pointee!.pointee.CreateInterfaceIterator(dev, &request, &iterator)
        guard kr == kIOReturnSuccess else {
            releaseDevice()
            throw USBError.openFailed("CreateInterfaceIterator", kr)
        }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            guard let candidate = Self.queryInterface(service: service,
                                                      typeID: Self.interfaceUserClientTypeID,
                                                      interfaceID: Self.interfaceInterfaceID500,
                                                      as: InterfaceInterface.self)
            else { continue }

            var opened = candidate.pointee!.pointee.USBInterfaceOpen(candidate)
            if opened != kIOReturnSuccess {
                opened = candidate.pointee!.pointee.USBInterfaceOpenSeize(candidate)
            }
            guard opened == kIOReturnSuccess else {
                _ = candidate.pointee?.pointee.Release(candidate)
                continue
            }

            if locatePipes(on: candidate) {
                interface = candidate
                return
            }
            _ = candidate.pointee!.pointee.USBInterfaceClose(candidate)
            _ = candidate.pointee?.pointee.Release(candidate)
        }

        releaseDevice()
        throw USBError.noMatchingInterface
    }

    /// Walk the interface's pipes looking for the two bulk endpoints we need.
    private func locatePipes(on iface: UnsafeMutablePointer<UnsafeMutablePointer<InterfaceInterface>?>) -> Bool {
        var endpointCount: UInt8 = 0
        guard iface.pointee!.pointee.GetNumEndpoints(iface, &endpointCount) == kIOReturnSuccess else {
            return false
        }
        var foundOut = false
        var foundIn = false
        // Pipe 0 is always the control endpoint.
        for pipe in 1...max(1, endpointCount) {
            var direction: UInt8 = 0, number: UInt8 = 0, transferType: UInt8 = 0
            var maxPacketSize: UInt16 = 0, interval: UInt8 = 0
            let kr = iface.pointee!.pointee.GetPipeProperties(iface, pipe, &direction, &number,
                                                              &transferType, &maxPacketSize, &interval)
            guard kr == kIOReturnSuccess else { continue }
            guard transferType == UInt8(kUSBBulk) else { continue }

            let address = number | (direction == UInt8(kUSBIn) ? 0x80 : 0x00)
            if address == outEndpoint { outPipe = pipe; foundOut = true }
            if address == inEndpoint { inPipe = pipe; foundIn = true }
        }
        return foundOut && foundIn
    }

    public func close() {
        if let iface = interface {
            _ = iface.pointee?.pointee.USBInterfaceClose(iface)
            _ = iface.pointee?.pointee.Release(iface)
            interface = nil
        }
        releaseDevice()
        outPipe = 0
        inPipe = 0
    }

    private func releaseDevice() {
        if let dev = device {
            _ = dev.pointee?.pointee.USBDeviceClose(dev)
            _ = dev.pointee?.pointee.Release(dev)
            device = nil
        }
    }

    // MARK: Transfers

    public func write(_ data: Data, timeout: TimeInterval) throws {
        guard let iface = interface else { throw USBError.notOpen }
        guard !data.isEmpty else { return }
        let milliseconds = UInt32(max(1, timeout * 1000))
        var buffer = [UInt8](data)
        let kr = buffer.withUnsafeMutableBytes { raw -> IOReturn in
            guard let base = raw.baseAddress else { return kIOReturnBadArgument }
            return iface.pointee!.pointee.WritePipeTO(iface, outPipe, base, UInt32(data.count),
                                                      milliseconds, milliseconds)
        }
        if kr == USBReturn.pipeStalled {
            _ = iface.pointee!.pointee.ClearPipeStallBothEnds(iface, outPipe)
            throw USBError.transferFailed("write (pipe stalled)", kr)
        }
        guard kr == kIOReturnSuccess else { throw USBError.transferFailed("write", kr) }
    }

    public func read(maxBytes: Int = 16384, timeout: TimeInterval) throws -> Data {
        guard let iface = interface else { throw USBError.notOpen }
        let milliseconds = UInt32(max(1, timeout * 1000))
        var buffer = [UInt8](repeating: 0, count: maxBytes)
        var size = UInt32(maxBytes)
        let kr = buffer.withUnsafeMutableBytes { raw -> IOReturn in
            guard let base = raw.baseAddress else { return kIOReturnBadArgument }
            return iface.pointee!.pointee.ReadPipeTO(iface, inPipe, base, &size,
                                                     milliseconds, milliseconds)
        }
        switch kr {
        case kIOReturnSuccess:
            return Data(buffer[0..<Int(size)])
        case USBReturn.transactionTimeout, kIOReturnTimeout, kIOReturnAborted:
            // A short read that timed out still delivers whatever arrived.
            return size > 0 ? Data(buffer[0..<Int(size)]) : Data()
        case USBReturn.pipeStalled:
            _ = iface.pointee!.pointee.ClearPipeStallBothEnds(iface, inPipe)
            return Data()
        default:
            throw USBError.transferFailed("read", kr)
        }
    }

    // MARK: Discovery

    /// Every USB device currently attached whose VID/PID appears in `identifiers`.
    public static func discover(identifiers: [(vendor: Int, product: Int)]) -> [USBDeviceInfo] {
        var found: [USBDeviceInfo] = []
        for className in ["IOUSBHostDevice", "IOUSBDevice"] {
            guard let matching = IOServiceMatching(className) else { continue }
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
                continue
            }
            defer { IOObjectRelease(iterator) }
            while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
                defer { IOObjectRelease(service) }
                guard let vendor = intProperty(service, "idVendor"),
                      let product = intProperty(service, "idProduct") else { continue }
                guard identifiers.contains(where: { $0.vendor == vendor && $0.product == product }) else {
                    continue
                }
                let info = USBDeviceInfo(
                    vendorID: vendor,
                    productID: product,
                    productName: stringProperty(service, "USB Product Name") ?? stringProperty(service, "kUSBProductString"),
                    vendorName: stringProperty(service, "USB Vendor Name"),
                    serialNumber: stringProperty(service, "USB Serial Number"),
                    locationID: intProperty(service, "locationID") ?? 0)
                if !found.contains(where: { $0.id == info.id }) { found.append(info) }
            }
            if !found.isEmpty { break }
        }
        return found.sorted { $0.locationID < $1.locationID }
    }

    private static func findService(matching info: USBDeviceInfo) -> io_service_t? {
        for className in ["IOUSBHostDevice", "IOUSBDevice"] {
            guard let matching = IOServiceMatching(className) else { continue }
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
                continue
            }
            defer { IOObjectRelease(iterator) }
            while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
                let vendor = intProperty(service, "idVendor")
                let product = intProperty(service, "idProduct")
                let location = intProperty(service, "locationID") ?? 0
                if vendor == info.vendorID, product == info.productID,
                   info.locationID == 0 || location == info.locationID {
                    return service      // caller releases
                }
                IOObjectRelease(service)
            }
        }
        return nil
    }

    private static func queryInterface<T>(service: io_service_t, typeID: CFUUID, interfaceID: CFUUID,
                                          as type: T.Type) -> UnsafeMutablePointer<UnsafeMutablePointer<T>?>? {
        var plugIn: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(service, typeID, Self.plugInInterfaceID,
                                                &plugIn, &score) == KERN_SUCCESS,
              let plugIn else { return nil }
        defer { _ = plugIn.pointee?.pointee.Release(plugIn) }

        var raw: LPVOID?
        let hr = withUnsafeMutablePointer(to: &raw) { pointer in
            plugIn.pointee!.pointee.QueryInterface(
                plugIn, CFUUIDGetUUIDBytes(interfaceID),
                UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: LPVOID?.self))
        }
        guard hr == S_OK, let raw else { return nil }
        return raw.assumingMemoryBound(to: UnsafeMutablePointer<T>?.self)
    }

    private static func stringProperty(_ service: io_object_t, _ key: String) -> String? {
        guard let cf = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return cf.takeRetainedValue() as? String
    }

    private static func intProperty(_ service: io_object_t, _ key: String) -> Int? {
        guard let cf = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return (cf.takeRetainedValue() as? NSNumber)?.intValue
    }
}
