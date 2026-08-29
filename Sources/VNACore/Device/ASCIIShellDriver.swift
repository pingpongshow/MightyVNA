import Foundation

/// Driver for the text shell used by the original NanoVNA, NanoVNA-H/H4 and the
/// SYSJOINT NanoVNA-F family (including the NanoVNA-F V2).
///
/// The shell echoes each command, prints its output, then a `ch> ` prompt.
public final class ASCIIShellDriver: VNADriver {

    public private(set) var info: DeviceInfo
    public var isConnected: Bool { port.isOpen }
    public var trafficHandler: ((TrafficLogEntry) -> Void)?

    private let port: SerialPort
    private static let prompt = Data("ch> ".utf8)

    /// Fast path: `scan start stop points mask` returns the whole sweep in one command.
    private var scanWithMaskSupported: Bool?
    private var isPaused = false

    public init(portPath: String, model: DeviceModel = DeviceCatalog.genericASCII) {
        self.port = SerialPort(path: portPath)
        self.info = DeviceInfo(model: model, portPath: portPath)
    }

    // MARK: - Connection

    public func connect() throws {
        try port.open()
        log(.note, "Opened \(port.path)")
        // Wake the shell and swallow whatever banner is pending.
        port.flushAll()
        _ = try? runCommand("", timeout: 1.5)
        try identify()
    }

    public func disconnect() {
        if port.isOpen {
            _ = try? runCommand("resume", timeout: 0.7)
        }
        port.close()
        log(.note, "Closed \(port.path)")
    }

    private func identify() throws {
        let version = (try? runCommand("version", timeout: 2)) ?? ""
        let boardInfo = (try? runCommand("info", timeout: 2)) ?? ""
        let banner = [version, boardInfo].filter { !$0.isEmpty }.joined(separator: "\n")
        info.banner = banner
        info.firmwareVersion = version.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""

        for line in boardInfo.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.lowercased().hasPrefix("build time:") {
                info.buildTime = String(l.dropFirst("build time:".count)).trimmingCharacters(in: .whitespaces)
            } else if l.lowercased().hasPrefix("kernel:") || l.lowercased().hasPrefix("board:") {
                if info.hardwareRevision.isEmpty {
                    info.hardwareRevision = l
                }
            }
        }

        if let matched = DeviceIdentity.model(fromBanner: banner) {
            info.model = matched
            info.screen = matched.screen
        }

        // Learn the command set so optional features can be greyed out accurately.
        if let help = try? runCommand("help", timeout: 3) {
            var commands = Set<String>()
            for token in help.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" || $0 == "," }) {
                let t = token.trimmingCharacters(in: CharacterSet(charactersIn: ":;"))
                if !t.isEmpty && t.count < 24 { commands.insert(t) }
            }
            commands.remove("Commands")
            info.supportedCommands = commands
        }

        info.batteryMillivolts = try? readBattery()
        log(.note, "Identified as \(info.model.name)")
    }

    // MARK: - Command plumbing

    @discardableResult
    private func runCommand(_ command: String, timeout: TimeInterval) throws -> String {
        guard port.isOpen else { throw DriverError.notConnected }
        port.flushInput()
        if !command.isEmpty { log(.sent, command) }
        try port.write(command + "\r\n")
        let data = try port.readUntil(Self.prompt, timeout: timeout, idleTimeout: max(0.35, timeout / 3))
        let text = String(decoding: data, as: UTF8.self)
        let cleaned = strip(response: text, command: command)
        if !cleaned.isEmpty { log(.received, cleaned) }
        return cleaned
    }

    /// Remove the echoed command and the trailing prompt.
    private func strip(response: String, command: String) -> String {
        var lines = response.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces) == command {
            lines.removeFirst()
        }
        while let last = lines.last,
              last.trimmingCharacters(in: .whitespaces).isEmpty || last.hasSuffix("ch>") || last.trimmingCharacters(in: .whitespaces) == "ch>" {
            lines.removeLast()
            if lines.isEmpty { break }
        }
        // The prompt sometimes arrives glued to the last data line.
        if var last = lines.last, let range = last.range(of: "ch>") {
            last.removeSubrange(range.lowerBound..<last.endIndex)
            lines[lines.count - 1] = last.trimmingCharacters(in: .whitespaces)
            if lines[lines.count - 1].isEmpty { lines.removeLast() }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func sendRaw(_ line: String, timeout: TimeInterval) throws -> String {
        try runCommand(line, timeout: timeout)
    }

    // MARK: - Sweeping

    public func sweep(start: Double, stop: Double, points: Int) throws -> SweepFrame {
        guard port.isOpen else { throw DriverError.notConnected }
        let n = max(2, min(points, info.model.maxHardwarePoints))
        let s = Int(start.rounded())
        let e = Int(stop.rounded())

        if scanWithMaskSupported != false {
            if let frame = try attemptFastScan(start: s, stop: e, points: n) {
                scanWithMaskSupported = true
                return frame
            }
            scanWithMaskSupported = false
            log(.note, "Falling back to sweep/frequencies/data (device has no `scan` output mask)")
        }
        return try classicSweep(start: s, stop: e, points: n)
    }

    /// `scan start stop points 7` → one line per point: freq s11re s11im s21re s21im
    private func attemptFastScan(start: Int, stop: Int, points: Int) throws -> SweepFrame? {
        let timeout = sweepTimeout(points: points)
        let response = try runCommand("scan \(start) \(stop) \(points) 7", timeout: timeout)
        guard !response.isEmpty else { return nil }
        if response.lowercased().contains("usage") || response.lowercased().contains("error") { return nil }

        var frequencies: [Double] = []
        var s11: [Complex] = []
        var s21: [Complex] = []
        for line in response.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Double($0) }
            guard parts.count >= 5 else { continue }
            frequencies.append(parts[0])
            s11.append(Complex(parts[1], parts[2]))
            s21.append(Complex(parts[3], parts[4]))
        }
        guard frequencies.count >= points / 2, frequencies.count > 2 else { return nil }
        learnPointLimit(returned: frequencies.count, requested: points)
        return SweepFrame(frequencies: frequencies, s11: s11, s21: s21)
    }

    /// Universal path supported by every text firmware.
    private func classicSweep(start: Int, stop: Int, points: Int) throws -> SweepFrame {
        let timeout = sweepTimeout(points: points)
        if info.supports("sweep") {
            _ = try runCommand("sweep \(start) \(stop) \(points)", timeout: 3)
        } else {
            _ = try runCommand("scan \(start) \(stop) \(points)", timeout: timeout)
        }
        // Give the instrument one complete pass so the buffers hold this range.
        _ = try? runCommand("data 0", timeout: timeout)

        let freqText = try runCommand("frequencies", timeout: timeout)
        let frequencies = freqText.split(separator: "\n").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard frequencies.count > 2 else { throw DriverError.badResponse("no frequency list returned") }
        learnPointLimit(returned: frequencies.count, requested: points)

        let s11 = try readComplexArray(command: "data 0", expected: frequencies.count, timeout: timeout)
        let s21 = try readComplexArray(command: "data 1", expected: frequencies.count, timeout: timeout)
        return SweepFrame(frequencies: frequencies, s11: s11, s21: s21)
    }

    private func readComplexArray(command: String, expected: Int, timeout: TimeInterval) throws -> [Complex] {
        let text = try runCommand(command, timeout: timeout)
        var values: [Complex] = []
        values.reserveCapacity(expected)
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Double($0) }
            guard parts.count >= 2 else { continue }
            values.append(Complex(parts[0], parts[1]))
        }
        if values.count < expected {
            values.append(contentsOf: [Complex](repeating: .zero, count: expected - values.count))
        } else if values.count > expected {
            values = Array(values.prefix(expected))
        }
        return values
    }

    /// Firmware often has a fixed sweep length. When the device returns fewer points
    /// than we asked for, remember that limit so the session can segment correctly.
    private func learnPointLimit(returned: Int, requested: Int) {
        guard returned > 2, returned < requested else { return }
        if returned < info.model.maxHardwarePoints {
            info.model.maxHardwarePoints = returned
            log(.note, "Device returns \(returned) points per sweep; sweeps will be segmented to match")
        }
    }

    private func sweepTimeout(points: Int) -> TimeInterval {
        // Slow IF bandwidths on low frequencies can take a while.
        max(6, Double(points) * 0.06 + 4)
    }

    public func pause() throws {
        guard info.supports("pause") else { return }
        _ = try runCommand("pause", timeout: 2)
        isPaused = true
    }

    public func resume() throws {
        guard info.supports("resume") else { return }
        _ = try runCommand("resume", timeout: 2)
        isPaused = false
    }

    // MARK: - Extras

    public func readBattery() throws -> Int? {
        guard info.supports("vbat") else { return nil }
        let text = try runCommand("vbat", timeout: 2)
        let digits = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        return digits.first
    }

    public func captureScreen() throws -> ScreenCapture {
        guard port.isOpen else { throw DriverError.notConnected }
        guard info.supports("capture") else { throw DriverError.unsupported("screen capture") }
        port.flushAll()
        log(.sent, "capture")
        try port.write("capture\r\n")

        // Read until the stream goes idle, then match the byte count to a known screen size.
        var data = Data()
        let deadline = Date().addingTimeInterval(12)
        var lastActivity = Date()
        while Date() < deadline {
            let chunk = try port.readAvailable(maxBytes: 32768, timeout: 0.25)
            if chunk.isEmpty {
                if Date().timeIntervalSince(lastActivity) > 0.9 && data.count > 1024 { break }
                continue
            }
            lastActivity = Date()
            data.append(chunk)
        }

        // Drop the echoed command line and the trailing prompt bytes.
        if let newline = data.firstIndex(of: 0x0A), newline < 24 {
            data = data.subdata(in: (newline + 1)..<data.count)
        }
        if let promptRange = data.range(of: Self.prompt, options: .backwards) {
            data = data.subdata(in: 0..<promptRange.lowerBound)
        }
        while let last = data.last, last == 0x0A || last == 0x0D || last == 0x20 { data.removeLast() }

        let size: ScreenSize
        if let matched = ScreenSize.matching(byteCount: data.count) {
            size = matched
        } else if let declared = info.screen, data.count >= declared.byteCount {
            size = declared
        } else if let best = ScreenSize.known.filter({ $0.byteCount <= data.count }).max(by: { $0.byteCount < $1.byteCount }) {
            size = best
        } else {
            throw DriverError.badResponse("screenshot returned \(data.count) bytes, which matches no known screen size")
        }
        info.screen = size
        let payload = data.prefix(size.byteCount)
        return ScreenCapture(width: size.width, height: size.height,
                             rgba: rgb565BigEndianToRGBA(Data(payload), width: size.width, height: size.height))
    }

    // MARK: - On-device calibration passthrough

    public func deviceCalibration(_ subcommand: String) throws -> String {
        try runCommand("cal \(subcommand)", timeout: 8)
    }

    public func saveDeviceSlot(_ slot: Int) throws {
        _ = try runCommand("save \(slot)", timeout: 4)
    }

    public func recallDeviceSlot(_ slot: Int) throws {
        _ = try runCommand("recall \(slot)", timeout: 4)
    }

    public func setElectricalDelay(picoseconds: Double) throws {
        _ = try runCommand("edelay \(Int(picoseconds.rounded()))", timeout: 2)
    }

    public func setBandwidth(_ value: Int) throws {
        _ = try runCommand("bandwidth \(value)", timeout: 2)
    }

    public func setOutputPower(_ level: Int) throws {
        _ = try runCommand("power \(level)", timeout: 2)
    }

    // MARK: - Logging

    private func log(_ direction: TrafficLogEntry.Direction, _ text: String) {
        guard let handler = trafficHandler, !text.isEmpty else { return }
        // Keep the console readable: very long payloads are summarised.
        let trimmed = text.count > 4000 ? String(text.prefix(4000)) + "\n… (\(text.count) bytes)" : text
        handler(TrafficLogEntry(direction: direction, text: trimmed))
    }
}
