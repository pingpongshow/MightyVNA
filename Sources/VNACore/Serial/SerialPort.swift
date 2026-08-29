import Foundation
import Darwin

public enum SerialError: LocalizedError {
    case cannotOpen(path: String, errno: Int32)
    case notOpen
    case configurationFailed(String, errno: Int32)
    case writeFailed(errno: Int32)
    case readFailed(errno: Int32)
    case timeout
    case disconnected

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let path, let e):
            return "Could not open \(path): \(String(cString: strerror(e))) (errno \(e))"
        case .notOpen:
            return "The serial port is not open."
        case .configurationFailed(let what, let e):
            return "Serial configuration failed (\(what)): \(String(cString: strerror(e)))"
        case .writeFailed(let e):
            return "Write failed: \(String(cString: strerror(e)))"
        case .readFailed(let e):
            return "Read failed: \(String(cString: strerror(e)))"
        case .timeout:
            return "Timed out waiting for the device to respond."
        case .disconnected:
            return "The device disconnected."
        }
    }
}

/// Blocking POSIX serial port with select()-based timeouts.
/// All access is expected to happen from a single dedicated queue.
public final class SerialPort {

    public let path: String
    private var fd: Int32 = -1
    private var originalAttributes = termios()

    public var isOpen: Bool { fd >= 0 }

    public init(path: String) {
        self.path = path
    }

    deinit { close() }

    public func open(baudRate: speed_t = 115200) throws {
        guard fd < 0 else { return }

        let handle = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard handle >= 0 else { throw SerialError.cannotOpen(path: path, errno: errno) }

        // Claim the port exclusively so a second app cannot fight us for it.
        if ioctl(handle, TIOCEXCL) == -1 {
            let e = errno
            Darwin.close(handle)
            throw SerialError.configurationFailed("exclusive access", errno: e)
        }
        // Switch back to blocking; timeouts are handled with select().
        if fcntl(handle, F_SETFL, 0) == -1 {
            let e = errno
            Darwin.close(handle)
            throw SerialError.configurationFailed("clearing O_NONBLOCK", errno: e)
        }

        var attrs = termios()
        if tcgetattr(handle, &attrs) == -1 {
            let e = errno
            Darwin.close(handle)
            throw SerialError.configurationFailed("tcgetattr", errno: e)
        }
        originalAttributes = attrs

        cfmakeraw(&attrs)
        attrs.c_cflag |= tcflag_t(CREAD | CLOCAL)
        attrs.c_cflag &= ~tcflag_t(CSIZE)
        attrs.c_cflag |= tcflag_t(CS8)
        attrs.c_cflag &= ~tcflag_t(PARENB)
        attrs.c_cflag &= ~tcflag_t(CSTOPB)
        attrs.c_cflag &= ~tcflag_t(CRTSCTS)
        attrs.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        withUnsafeMutablePointer(to: &attrs.c_cc) { ccPtr in
            ccPtr.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
                cc[Int(VMIN)] = 0
                cc[Int(VTIME)] = 0
            }
        }
        cfsetispeed(&attrs, baudRate)
        cfsetospeed(&attrs, baudRate)

        if tcsetattr(handle, TCSANOW, &attrs) == -1 {
            let e = errno
            Darwin.close(handle)
            throw SerialError.configurationFailed("tcsetattr", errno: e)
        }

        fd = handle
        flushInput()
    }

    public func close() {
        guard fd >= 0 else { return }
        tcdrain(fd)
        _ = tcsetattr(fd, TCSANOW, &originalAttributes)
        Darwin.close(fd)
        fd = -1
    }

    public func flushInput() {
        guard fd >= 0 else { return }
        _ = tcflush(fd, TCIFLUSH)
    }

    public func flushAll() {
        guard fd >= 0 else { return }
        _ = tcflush(fd, TCIOFLUSH)
    }

    // MARK: - Writing

    public func write(_ data: Data) throws {
        guard fd >= 0 else { throw SerialError.notOpen }
        var offset = 0
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while offset < data.count {
                let written = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if written < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    throw SerialError.writeFailed(errno: errno)
                }
                if written == 0 { throw SerialError.disconnected }
                offset += written
            }
        }
    }

    public func write(_ string: String) throws {
        try write(Data(string.utf8))
    }

    // MARK: - Reading

    /// Wait until at least one byte is readable or the timeout elapses.
    /// Returns false on timeout.
    public func waitForData(timeout: TimeInterval) throws -> Bool {
        guard fd >= 0 else { throw SerialError.notOpen }
        var readSet = fd_set()
        fdZero(&readSet)
        fdSet(fd, &readSet)
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        let result = select(fd + 1, &readSet, nil, nil, &tv)
        if result < 0 {
            if errno == EINTR { return false }
            throw SerialError.readFailed(errno: errno)
        }
        return result > 0
    }

    /// Read whatever is currently available, up to `maxBytes`.
    /// Returns an empty Data on timeout.
    public func readAvailable(maxBytes: Int = 4096, timeout: TimeInterval = 0.2) throws -> Data {
        guard try waitForData(timeout: timeout) else { return Data() }
        guard fd >= 0 else { throw SerialError.notOpen }
        var buffer = [UInt8](repeating: 0, count: maxBytes)
        let n = buffer.withUnsafeMutableBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return -1 }
            return Darwin.read(fd, base, maxBytes)
        }
        if n < 0 {
            if errno == EAGAIN || errno == EINTR { return Data() }
            throw SerialError.readFailed(errno: errno)
        }
        if n == 0 { throw SerialError.disconnected }
        return Data(buffer[0..<n])
    }

    /// Read exactly `count` bytes or throw on timeout.
    public func readExactly(_ count: Int, timeout: TimeInterval) throws -> Data {
        var out = Data()
        out.reserveCapacity(count)
        let deadline = Date().addingTimeInterval(timeout)
        while out.count < count {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw SerialError.timeout }
            let chunk = try readAvailable(maxBytes: count - out.count, timeout: min(remaining, 0.25))
            out.append(chunk)
        }
        return out
    }

    /// Read until `terminator` appears or the timeout elapses.
    /// Returns everything read, including the terminator.
    public func readUntil(_ terminator: Data, timeout: TimeInterval, idleTimeout: TimeInterval = 1.0) throws -> Data {
        var out = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var lastActivity = Date()
        while true {
            if out.count >= terminator.count,
               out.range(of: terminator, options: .backwards, in: max(0, out.count - terminator.count - 64)..<out.count) != nil {
                return out
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw SerialError.timeout }
            let chunk = try readAvailable(maxBytes: 8192, timeout: min(remaining, 0.15))
            if chunk.isEmpty {
                if Date().timeIntervalSince(lastActivity) > idleTimeout, !out.isEmpty { return out }
                continue
            }
            lastActivity = Date()
            out.append(chunk)
        }
    }

    // MARK: - fd_set helpers (fd_set is an opaque tuple in Swift)

    private func fdZero(_ set: inout fd_set) {
        set = fd_set()
    }

    private func fdSet(_ descriptor: Int32, _ set: inout fd_set) {
        let intOffset = Int(descriptor / 32)
        let bitOffset = Int(descriptor % 32)
        let mask = Int32(bitPattern: UInt32(1) << UInt32(bitOffset))
        withUnsafeMutablePointer(to: &set.fds_bits) { ptr in
            ptr.withMemoryRebound(to: Int32.self, capacity: 32) { bits in
                bits[intOffset] |= mask
            }
        }
    }
}
