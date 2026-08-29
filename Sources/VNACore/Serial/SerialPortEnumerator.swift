import Foundation
import IOKit
import IOKit.serial

/// A serial device discovered on the system, with USB metadata when available.
public struct SerialPortInfo: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var path: String              // /dev/cu.usbmodem...
    public var dialInPath: String?       // /dev/tty....
    public var name: String              // BSD name
    public var vendorID: Int?
    public var productID: Int?
    public var usbProductName: String?
    public var usbVendorName: String?
    public var serialNumber: String?
    public var locationID: Int?

    public var displayName: String {
        if let p = usbProductName, !p.isEmpty { return p }
        return name
    }

    public var identifierString: String {
        guard let v = vendorID, let p = productID else { return "—" }
        return String(format: "%04X:%04X", v, p)
    }

    /// Devices that are never a VNA — filtered out of the default list.
    public var isLikelyIrrelevant: Bool {
        let lower = path.lowercased()
        return lower.contains("bluetooth") || lower.contains("debug-console") || lower.contains("wlan")
    }
}

public enum SerialPortEnumerator {

    /// All callout (cu.*) serial devices on the system.
    public static func availablePorts() -> [SerialPortInfo] {
        var results: [SerialPortInfo] = []
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { return [] }

        // Restrict to modem/callout style devices.
        let dict = matching as NSMutableDictionary
        dict[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes

        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            guard let callout = stringProperty(service, kIOCalloutDeviceKey) else { continue }

            var info = SerialPortInfo(
                path: callout,
                dialInPath: stringProperty(service, kIODialinDeviceKey),
                name: stringProperty(service, kIOTTYDeviceKey) ?? (callout as NSString).lastPathComponent
            )

            // USB metadata lives on an ancestor node.
            var node = service
            var depth = 0
            var owned = false
            while depth < 12 {
                if info.vendorID == nil { info.vendorID = intProperty(node, "idVendor") }
                if info.productID == nil { info.productID = intProperty(node, "idProduct") }
                if info.usbProductName == nil {
                    info.usbProductName = stringProperty(node, "USB Product Name") ?? stringProperty(node, "Product Name")
                }
                if info.usbVendorName == nil {
                    info.usbVendorName = stringProperty(node, "USB Vendor Name")
                }
                if info.serialNumber == nil {
                    info.serialNumber = stringProperty(node, "USB Serial Number")
                }
                if info.locationID == nil { info.locationID = intProperty(node, "locationID") }
                if info.vendorID != nil && info.usbProductName != nil { break }

                var parent: io_registry_entry_t = 0
                let status = IORegistryEntryGetParentEntry(node, kIOServicePlane, &parent)
                if owned { IOObjectRelease(node) }
                guard status == KERN_SUCCESS, parent != IO_OBJECT_NULL else { break }
                node = parent
                owned = true
                depth += 1
            }
            if owned && node != service { IOObjectRelease(node) }

            results.append(info)
        }

        return results.sorted { $0.path < $1.path }
    }

    /// Ports that plausibly host a VNA, best candidates first.
    public static func candidatePorts() -> [SerialPortInfo] {
        availablePorts()
            .filter { !$0.isLikelyIrrelevant }
            .sorted { a, b in
                let sa = DeviceIdentity.likelihoodScore(for: a)
                let sb = DeviceIdentity.likelihoodScore(for: b)
                if sa != sb { return sa > sb }
                return a.path < b.path
            }
    }

    // MARK: - Registry helpers

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
