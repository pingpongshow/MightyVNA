import XCTest
@testable import VNACore

final class LibreVNAProtocolTests: XCTestCase {

    func testCRC32MatchesKnownVector() {
        // The firmware uses CRC-32/ISO-HDLC, whose check value over "123456789" is 0xCBF43926.
        XCTAssertEqual(LibreVNA.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(LibreVNA.crc32(Data()), 0)
    }

    func testPacketRoundTrip() {
        let payload = Data([1, 2, 3, 4, 5])
        let packet = LibreVNA.Packet(type: .sweepSettings, payload: payload)
        let encoded = LibreVNA.encode(packet)

        XCTAssertEqual(encoded[0], LibreVNA.headerByte)
        XCTAssertEqual(Int(encoded[1]) | (Int(encoded[2]) << 8), encoded.count)
        XCTAssertEqual(encoded[3], LibreVNA.PacketType.sweepSettings.rawValue)
        XCTAssertEqual(encoded.count, LibreVNA.overheadLength + payload.count)

        guard case .packet(let decoded, let consumed) = LibreVNA.decodeOne(encoded) else {
            return XCTFail("did not decode")
        }
        XCTAssertEqual(decoded, packet)
        XCTAssertEqual(consumed, encoded.count)
    }

    func testDatapointPacketsCarryZeroCRC() {
        var point = LibreVNA.Datapoint()
        point.frequency = 1_000_000
        point.add(Complex(1, 0), stage: 0, port: 0, reference: true)
        let encoded = LibreVNA.encode(LibreVNA.Packet(type: .vnaDatapoint, payload: point.encoded()))
        let crc = encoded.suffix(4)
        XCTAssertEqual(Array(crc), [0, 0, 0, 0])
        guard case .packet = LibreVNA.decodeOne(encoded) else {
            return XCTFail("a zero-CRC datapoint must still decode")
        }
    }

    func testIncompleteBufferWaits() {
        let encoded = LibreVNA.encode(LibreVNA.Packet(type: .ack))
        for cut in 1..<encoded.count {
            XCTAssertEqual(LibreVNA.decodeOne(encoded.prefix(cut)), .incomplete,
                           "a \(cut)-byte prefix should be treated as incomplete")
        }
    }

    func testGarbageBeforeSyncIsSkipped() {
        var buffer = Data([0x11, 0x22, 0x33])
        buffer.append(LibreVNA.encode(LibreVNA.Packet(type: .ack)))
        let packets = LibreVNA.drain(&buffer)
        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets.first?.type, .ack)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testCorruptedCRCIsRejectedAndStreamResynchronises() {
        var corrupted = LibreVNA.encode(LibreVNA.Packet(type: .deviceInfo, payload: Data([9, 9, 9])))
        corrupted[corrupted.count - 1] ^= 0xFF          // break the CRC
        var buffer = corrupted
        buffer.append(LibreVNA.encode(LibreVNA.Packet(type: .ack)))
        let packets = LibreVNA.drain(&buffer)
        XCTAssertEqual(packets.map(\.type), [.ack], "the corrupt packet must be dropped, the good one kept")
    }

    func testDrainHandlesSeveralPacketsAndAPartialTail() {
        var buffer = Data()
        buffer.append(LibreVNA.encode(LibreVNA.Packet(type: .ack)))
        buffer.append(LibreVNA.encode(LibreVNA.Packet(type: .nack)))
        let partial = LibreVNA.encode(LibreVNA.Packet(type: .deviceStatus, payload: Data([1, 2, 3, 4])))
        buffer.append(partial.prefix(5))

        let packets = LibreVNA.drain(&buffer)
        XCTAssertEqual(packets.map(\.type), [.ack, .nack])
        XCTAssertEqual(buffer.count, 5, "the partial packet stays in the buffer")

        buffer.append(partial.dropFirst(5))
        let rest = LibreVNA.drain(&buffer)
        XCTAssertEqual(rest.map(\.type), [.deviceStatus])
        XCTAssertTrue(buffer.isEmpty)
    }

    func testSweepSettingsLayout() {
        var settings = LibreVNA.SweepSettings()
        settings.startHz = 0x0102_0304_0506_0708
        settings.stopHz = 6_000_000_000
        settings.points = 501
        settings.ifBandwidth = 10_000
        settings.cdbmStart = -1_000
        settings.cdbmStop = -500
        settings.stages = 1
        settings.port1Stage = 0
        settings.port2Stage = 1
        settings.logSweep = true
        settings.suppressPeaks = true
        settings.fixedPowerSetting = false
        settings.dwellTimeMicroseconds = 42

        let d = [UInt8](settings.encoded())
        XCTAssertEqual(d.count, 31, "SweepSettings is 31 packed bytes")
        XCTAssertEqual(d.littleEndian(UInt64.self, at: 0), 0x0102_0304_0506_0708)
        XCTAssertEqual(d.littleEndian(UInt64.self, at: 8), 6_000_000_000)
        XCTAssertEqual(d.littleEndian(UInt16.self, at: 16), 501)
        XCTAssertEqual(d.littleEndian(UInt32.self, at: 18), 10_000)
        XCTAssertEqual(Int16(bitPattern: d.littleEndian(UInt16.self, at: 22)), -1_000)

        // flags byte: suppressPeaks (bit 2) and logSweep (bit 4) set, fixedPowerSetting (bit 3) clear
        XCTAssertEqual(d[24] & (1 << 2), 1 << 2)
        XCTAssertEqual(d[24] & (1 << 3), 0)
        XCTAssertEqual(d[24] & (1 << 4), 1 << 4)

        // stage word: stages in bits 0-2, port1Stage in 3-5, port2Stage in 6-8
        let stageWord = d.littleEndian(UInt16.self, at: 25)
        XCTAssertEqual(stageWord & 0x07, 1)
        XCTAssertEqual((stageWord >> 3) & 0x07, 0)
        XCTAssertEqual((stageWord >> 6) & 0x07, 1)

        XCTAssertEqual(Int16(bitPattern: d.littleEndian(UInt16.self, at: 27)), -500)
        XCTAssertEqual(d.littleEndian(UInt16.self, at: 29), 42)
    }

    func testDeviceInfoRoundTrip() {
        var info = LibreVNA.DeviceInfo()
        info.protocolVersion = LibreVNA.protocolVersion
        info.firmwareMajor = 1
        info.firmwareMinor = 5
        info.firmwarePatch = 2
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

        let payload = info.encoded()
        XCTAssertEqual(payload.count, LibreVNA.DeviceInfo.encodedSize)
        guard let decoded = LibreVNA.DeviceInfo(payload: payload) else {
            return XCTFail("could not decode device info")
        }
        XCTAssertEqual(decoded, info)
        XCTAssertEqual(decoded.firmwareDescription, "1.5.2")
        XCTAssertEqual(decoded.hardwareRevision, "B")
    }

    func testDeviceInfoRejectsShortPayload() {
        XCTAssertNil(LibreVNA.DeviceInfo(payload: Data(repeating: 0, count: 20)))
    }

    func testDatapointSParameterExtraction() {
        // A two-port sweep: port 1 excited on stage 0, port 2 on stage 1.
        var point = LibreVNA.Datapoint()
        point.frequency = 145_000_000
        point.pointNumber = 7

        let ref1 = Complex(2, 0)
        let ref2 = Complex(0, 4)
        let b11 = Complex(0.5, 0.25)      // receiver 1 during stage 0
        let b21 = Complex(-1.5, 0.5)      // receiver 2 during stage 0
        let b12 = Complex(0.75, -0.5)     // receiver 1 during stage 1
        let b22 = Complex(1.0, 1.0)       // receiver 2 during stage 1

        point.add(b11, stage: 0, port: 0, reference: false)
        point.add(b21, stage: 0, port: 1, reference: false)
        point.add(ref1, stage: 0, port: 0, reference: true)
        point.add(b12, stage: 1, port: 0, reference: false)
        point.add(b22, stage: 1, port: 1, reference: false)
        point.add(ref2, stage: 1, port: 1, reference: true)

        guard let decoded = LibreVNA.Datapoint(payload: point.encoded()) else {
            return XCTFail("datapoint did not decode")
        }
        XCTAssertEqual(decoded.frequency, 145_000_000)
        XCTAssertEqual(decoded.pointNumber, 7)
        XCTAssertEqual(decoded.real.count, 6)

        func expect(_ got: Complex?, _ want: Complex, _ label: String) {
            guard let got else { return XCTFail("\(label) missing") }
            XCTAssertEqual(got.re, want.re, accuracy: 1e-6, label)
            XCTAssertEqual(got.im, want.im, accuracy: 1e-6, label)
        }
        expect(decoded.sParameter(receivePort: 1, excitePort: 1, stage: 0), b11 / ref1, "S11")
        expect(decoded.sParameter(receivePort: 2, excitePort: 1, stage: 0), b21 / ref1, "S21")
        expect(decoded.sParameter(receivePort: 1, excitePort: 2, stage: 1), b12 / ref2, "S12")
        expect(decoded.sParameter(receivePort: 2, excitePort: 2, stage: 1), b22 / ref2, "S22")
    }

    func testDatapointDistinguishesReferenceFromReceiver() {
        // The reference descriptor also has the port bit set, so a loose mask test would
        // confuse the two. Values must be matched on the reference bit exactly.
        var point = LibreVNA.Datapoint()
        point.add(Complex(9, 9), stage: 0, port: 0, reference: true)    // reference added FIRST
        point.add(Complex(1, 0), stage: 0, port: 0, reference: false)
        let decoded = LibreVNA.Datapoint(payload: point.encoded())!
        XCTAssertEqual(decoded.value(stage: 0, port: 0, reference: false)?.re, 1)
        XCTAssertEqual(decoded.value(stage: 0, port: 0, reference: true)?.re, 9)
    }

    func testDatapointReturnsNilForMissingReadings() {
        var point = LibreVNA.Datapoint()
        point.add(Complex(1, 0), stage: 0, port: 0, reference: true)
        let decoded = LibreVNA.Datapoint(payload: point.encoded())!
        XCTAssertNil(decoded.value(stage: 1, port: 0, reference: true))
        XCTAssertNil(decoded.sParameter(receivePort: 2, excitePort: 1, stage: 0))
    }

    func testDeviceStatusDecoding() {
        // source_locked (bit 3), LO locked (bit 4), FPGA configured (bit 2)
        let payload = Data([0b0001_1100, 45, 50, 38])
        guard let status = LibreVNA.DeviceStatus(payload: payload) else { return XCTFail("no status") }
        XCTAssertTrue(status.fpgaConfigured)
        XCTAssertTrue(status.sourceLocked)
        XCTAssertTrue(status.loLocked)
        XCTAssertFalse(status.adcOverload)
        XCTAssertEqual(status.temperatureMCU, 38)
        XCTAssertEqual(status.summary, "OK")
    }
}
