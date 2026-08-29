import XCTest
@testable import VNACore

final class LibreVNADriverTests: XCTestCase {

    private func makeDriver() throws -> (LibreVNADriver, LoopbackLibreVNATransport) {
        let transport = LoopbackLibreVNATransport()
        transport.sweepDelay = 0
        transport.noiseFloor = 0
        let driver = LibreVNADriver(transport: transport, portDescription: "loopback")
        try driver.connect()
        return (driver, transport)
    }

    func testConnectReadsDeviceLimits() throws {
        let (driver, _) = try makeDriver()
        XCTAssertTrue(driver.isConnected)
        XCTAssertEqual(driver.info.firmwareVersion, "1.5.0")
        XCTAssertEqual(driver.info.model.minFrequency, 100_000)
        XCTAssertEqual(driver.info.model.maxFrequency, 6e9)
        XCTAssertEqual(driver.info.model.maxHardwarePoints, 4501)
        XCTAssertTrue(driver.info.model.isFullTwoPort)
        XCTAssertEqual(driver.info.model.portCount, 2)
        XCTAssertTrue(driver.info.banner.contains("LibreVNA"))
        driver.disconnect()
        XCTAssertFalse(driver.isConnected)
    }

    func testConnectFailsCleanlyWhenTheDeviceSaysNothing() {
        final class SilentTransport: USBBulkTransport {
            var isOpen = false
            func open() throws { isOpen = true }
            func close() { isOpen = false }
            func write(_ data: Data, timeout: TimeInterval) throws {}
            func read(maxBytes: Int, timeout: TimeInterval) throws -> Data { Data() }
        }
        let driver = LibreVNADriver(transport: SilentTransport(), portDescription: "silent")
        XCTAssertThrowsError(try driver.connect())
        XCTAssertFalse(driver.isConnected)
    }

    func testFullTwoPortSweep() throws {
        let (driver, _) = try makeDriver()
        let frame = try driver.sweep(start: 200e6, stop: 400e6, points: 101)

        XCTAssertEqual(frame.count, 101)
        XCTAssertTrue(frame.isFullTwoPort, "a LibreVNA sweep must carry S12 and S22")
        XCTAssertEqual(frame.availableChannels, Channel.fullTwoPort)
        XCTAssertEqual(frame.startFrequency, 200e6, accuracy: 1)
        XCTAssertEqual(frame.stopFrequency, 400e6, accuracy: 1)

        // The synthetic filter peaks at 300 MHz on both transmission paths.
        let s21 = frame.s21.map { RF.dB($0.magnitude) }
        let s12 = frame.s12.map { RF.dB($0.magnitude) }
        let peak21 = TraceAnalysis.indexOfMaximum(s21)!
        let peak12 = TraceAnalysis.indexOfMaximum(s12)!
        XCTAssertEqual(frame.frequencies[peak21], 300e6, accuracy: 5e6)
        XCTAssertEqual(frame.frequencies[peak12], 300e6, accuracy: 5e6)

        // Passband: little reflection. Stopband: nearly all of it reflected.
        let mid = frame.nearestIndex(to: 300e6)
        let edge = frame.nearestIndex(to: 200e6)
        XCTAssertLessThan(frame.s11[mid].magnitude, 0.1, "the passband should be well matched")
        XCTAssertGreaterThan(frame.s11[edge].magnitude, 0.9)
        XCTAssertGreaterThan(frame.s22[edge].magnitude, 0.8)

        // Energy is conserved apart from the modelled 1.4 dB insertion loss.
        for i in frame.frequencies.indices {
            let total = frame.s11[i].magnitudeSquared + frame.s21[i].magnitudeSquared
            XCTAssertLessThanOrEqual(total, 1.01, "a passive DUT cannot create energy")
            XCTAssertGreaterThan(total, 0.7)
        }
        driver.disconnect()
    }

    func testForwardOnlySweepOmitsReverseData() throws {
        let (driver, _) = try makeDriver()
        driver.measureReverse = false
        let frame = try driver.sweep(start: 200e6, stop: 400e6, points: 51)
        XCTAssertEqual(frame.count, 51)
        XCTAssertFalse(frame.isFullTwoPort)
        XCTAssertTrue(frame.s12.isEmpty)
        XCTAssertFalse(frame.hasMeasured(.s22))
        // S11/S21 are still real measurements.
        XCTAssertTrue(frame.hasMeasured(.s11))
        XCTAssertTrue(frame.hasMeasured(.s21))
        driver.disconnect()
    }

    func testSweepIsClampedToTheHardwarePointLimit() throws {
        let transport = LoopbackLibreVNATransport()
        transport.sweepDelay = 0
        transport.limits.maxPoints = 64
        let driver = LibreVNADriver(transport: transport, portDescription: "loopback")
        try driver.connect()
        let frame = try driver.sweep(start: 1e6, stop: 100e6, points: 500)
        XCTAssertEqual(frame.count, 64)
        driver.disconnect()
    }

    func testIFBandwidthIsClampedToDeviceLimits() throws {
        let transport = LoopbackLibreVNATransport()
        transport.sweepDelay = 0
        transport.limits.minIFBandwidth = 500
        transport.limits.maxIFBandwidth = 5_000
        let driver = LibreVNADriver(transport: transport, portDescription: "loopback")
        driver.ifBandwidth = 100_000
        try driver.connect()
        XCTAssertLessThanOrEqual(driver.ifBandwidth, 5_000)
        XCTAssertGreaterThanOrEqual(driver.ifBandwidth, 500)
        driver.disconnect()
    }

    func testTextCommandsAreRejectedWithGuidance() throws {
        let (driver, _) = try makeDriver()
        XCTAssertThrowsError(try driver.sendRaw("scan 1 2 3", timeout: 1)) { error in
            XCTAssertTrue("\(error)".contains("binary packet protocol"))
        }
        let status = try driver.sendRaw("status", timeout: 1)
        XCTAssertTrue(status.contains("Status:"))
        driver.disconnect()
    }

    func testScreenCaptureIsRejected() throws {
        let (driver, _) = try makeDriver()
        XCTAssertThrowsError(try driver.captureScreen())
        driver.disconnect()
    }

    func testSessionSweepThroughTheSimulatedDriver() async throws {
        let session = DeviceSession()
        let info = try await session.connectLibreVNASimulator()
        XCTAssertTrue(info.model.isFullTwoPort)
        let frame = try await session.sweep(SweepConfiguration(start: 200e6, stop: 400e6, points: 101))
        XCTAssertEqual(frame.count, 101)
        XCTAssertTrue(frame.isFullTwoPort)
        await session.disconnect()
    }
}
