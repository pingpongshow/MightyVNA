import XCTest
@testable import VNACore

/// A driver that sweeps at most `pointLimit` points per pass, so segmentation can be tested.
private final class StubDriver: VNADriver {
    var info: DeviceInfo
    var isConnected = true
    var trafficHandler: ((TrafficLogEntry) -> Void)?
    private(set) var sweepCalls: [(start: Double, stop: Double, points: Int)] = []
    /// After this many calls, start reporting a smaller limit, mimicking firmware discovery.
    var shrinkAfterFirstCall = false

    init(pointLimit: Int) {
        var model = DeviceCatalog.genericASCII
        model.maxHardwarePoints = pointLimit
        model.minFrequency = 0
        model.maxFrequency = 10e9
        info = DeviceInfo(model: model, portPath: "stub")
    }

    func connect() throws {}
    func disconnect() { isConnected = false }

    func sweep(start: Double, stop: Double, points: Int) throws -> SweepFrame {
        sweepCalls.append((start, stop, points))
        let n = min(points, info.model.maxHardwarePoints)
        if shrinkAfterFirstCall, sweepCalls.count == 1 {
            info.model.maxHardwarePoints = max(2, info.model.maxHardwarePoints / 2)
        }
        let step = n > 1 ? (stop - start) / Double(max(1, points - 1)) : 0
        let frequencies = (0..<n).map { start + step * Double($0) }
        // Encode the frequency in the data so the stitching can be verified.
        let values = frequencies.map { Complex($0, 0) }
        return SweepFrame(frequencies: frequencies, s11: values, s21: values)
    }

    func sendRaw(_ line: String, timeout: TimeInterval) throws -> String { "" }
    func captureScreen() throws -> ScreenCapture { throw DriverError.unsupported("capture") }
    func readBattery() throws -> Int? { nil }
    func pause() throws {}
    func resume() throws {}
}

final class DeviceSessionTests: XCTestCase {

    /// Reach into the session's private driver slot the same way `connect` does.
    private func makeSession(with driver: VNADriver) -> DeviceSession {
        let session = DeviceSession()
        session.attachForTesting(driver)
        return session
    }

    func testSingleSegmentSweepPassesThrough() async throws {
        let stub = StubDriver(pointLimit: 401)
        let session = makeSession(with: stub)
        let frame = try await session.sweep(SweepConfiguration(start: 1e6, stop: 101e6, points: 101))
        XCTAssertEqual(frame.count, 101)
        XCTAssertEqual(stub.sweepCalls.count, 1)
        XCTAssertEqual(frame.startFrequency, 1e6, accuracy: 1)
        XCTAssertEqual(frame.stopFrequency, 101e6, accuracy: 1)
    }

    func testSegmentedSweepProducesContiguousGrid() async throws {
        let stub = StubDriver(pointLimit: 50)
        let session = makeSession(with: stub)
        let config = SweepConfiguration(start: 1e6, stop: 201e6, points: 201)
        let frame = try await session.sweep(config)

        XCTAssertEqual(frame.count, 201)
        XCTAssertEqual(stub.sweepCalls.count, 5)     // 50 + 50 + 50 + 50 + 1
        XCTAssertTrue(frame.isUniformGrid)
        let expected = config.frequencyGrid()
        for i in 0..<frame.count {
            XCTAssertEqual(frame.frequencies[i], expected[i], accuracy: 1)
        }
        // No zero padding anywhere: every sample carries real data.
        XCTAssertFalse(frame.s11.contains { $0.magnitudeSquared == 0 })
    }

    func testSegmentationAdaptsWhenTheLimitShrinksMidSweep() async throws {
        let stub = StubDriver(pointLimit: 100)
        stub.shrinkAfterFirstCall = true
        let session = makeSession(with: stub)
        let frame = try await session.sweep(SweepConfiguration(start: 1e6, stop: 301e6, points: 301))
        XCTAssertEqual(frame.count, 301, "shrinking limits must not leave gaps or zero padding")
        XCTAssertFalse(frame.s11.contains { $0.magnitudeSquared == 0 })
        XCTAssertTrue(frame.isUniformGrid)
    }

    func testSimulatorProducesPlausibleData() async throws {
        let session = DeviceSession()
        _ = try await session.connectSimulator()
        let frame = try await session.sweep(SweepConfiguration(start: 100e6, stop: 500e6, points: 201))
        XCTAssertEqual(frame.count, 201)
        // The synthetic filter peaks near 300 MHz on S21.
        let db = frame.s21.map { RF.dB($0.magnitude) }
        let peak = TraceAnalysis.indexOfMaximum(db)!
        XCTAssertEqual(frame.frequencies[peak], 300e6, accuracy: 20e6)
        // The synthetic antenna dips near 145 MHz on S11.
        let s11db = frame.s11.map { RF.dB($0.magnitude) }
        let dip = TraceAnalysis.indexOfMinimum(s11db)!
        XCTAssertEqual(frame.frequencies[dip], 145.5e6, accuracy: 10e6)
        await session.disconnect()
    }

    func testDeviceIdentificationFromBanner() {
        XCTAssertEqual(DeviceIdentity.model(fromBanner: "NanoVNA-F_V2 v1.2.3")?.id, "nanovna-f-v2")
        XCTAssertEqual(DeviceIdentity.model(fromBanner: "NanoVNA-H4 1.2.20")?.id, "nanovna-h4")
        XCTAssertEqual(DeviceIdentity.model(fromBanner: "LiteVNA64 v0.3.0")?.id, "litevna-64")
        XCTAssertNil(DeviceIdentity.model(fromBanner: "some other instrument"))
    }

    func testDeviceIdentificationFromVariant() {
        XCTAssertEqual(DeviceIdentity.model(fromVariant: 0x02).id, "nanovna-v2")
        XCTAssertEqual(DeviceIdentity.model(fromVariant: 0xFF).id, "generic-v2")
    }

    func testScreenSizeMatchingByByteCount() {
        XCTAssertEqual(ScreenSize.matching(byteCount: 320 * 240 * 2)?.width, 320)
        XCTAssertEqual(ScreenSize.matching(byteCount: 800 * 480 * 2)?.height, 480)
        XCTAssertNil(ScreenSize.matching(byteCount: 12345))
    }

    func testRGB565Conversion() {
        // Pure red, green, blue in big-endian RGB565.
        let data = Data([0xF8, 0x00, 0x07, 0xE0, 0x00, 0x1F])
        let rgba = rgb565BigEndianToRGBA(data, width: 3, height: 1)
        XCTAssertEqual(rgba[0], 255); XCTAssertEqual(rgba[1], 0);   XCTAssertEqual(rgba[2], 0)
        XCTAssertEqual(rgba[4], 0);   XCTAssertEqual(rgba[5], 255); XCTAssertEqual(rgba[6], 0)
        XCTAssertEqual(rgba[8], 0);   XCTAssertEqual(rgba[9], 0);   XCTAssertEqual(rgba[10], 255)
    }
}
