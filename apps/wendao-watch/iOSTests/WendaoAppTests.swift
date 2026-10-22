// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import AVFoundation
import SwiftUI
import WendaoKit
import XCTest

@testable import Wendao

@MainActor
final class WendaoAppTests: XCTestCase {
    func testBaseURLDefaultsToProductionAndPersistsOverride() {
        let saved = UserDefaults.standard.string(forKey: WendaoEnvironment.baseURLKey)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: WendaoEnvironment.baseURLKey)
            } else {
                UserDefaults.standard.removeObject(forKey: WendaoEnvironment.baseURLKey)
            }
        }
        UserDefaults.standard.removeObject(forKey: WendaoEnvironment.baseURLKey)
        XCTAssertEqual(WendaoEnvironment.baseURL, WendaoServer.production)

        let lan = URL(string: "http://192.168.1.20:3101")!
        WendaoEnvironment.baseURL = lan
        XCTAssertEqual(WendaoEnvironment.baseURL, lan)

        WendaoEnvironment.baseURL = WendaoServer.production
        XCTAssertNil(UserDefaults.standard.string(forKey: WendaoEnvironment.baseURLKey))
    }

    func testPhonePolicyRecordsAsPhone() {
        let policy = WendaoEnvironment.makePolicy()
        XCTAssertEqual(policy.localSource, .phone)
        XCTAssertEqual(policy.segmentDuration, 300)
        XCTAssertTrue(policy.store.root.path.hasSuffix("Wendao"))
    }

    func testPhoneNumberDigitCheck() {
        XCTAssertTrue("13800138000".allSatisfy(\.isASCIIDigit))
        XCTAssertFalse("1380013800٣".allSatisfy(\.isASCIIDigit))
    }

    func testHexColorParsing() {
        XCTAssertNotNil(Color(hex: "#3366ff"))
        XCTAssertNotNil(Color(hex: "3366FF"))
        XCTAssertNil(Color(hex: "#36f"))
        XCTAssertNil(Color(hex: nil))
    }

    func testRecorderSettingsAreAACMono16k() {
        let s = GaplessAudioEngine.fileSettings
        XCTAssertEqual(s[AVFormatIDKey] as? UInt32, kAudioFormatMPEG4AAC)
        XCTAssertEqual(s[AVSampleRateKey] as? Double, 16_000)
        XCTAssertEqual(s[AVNumberOfChannelsKey] as? Int, 1)
        XCTAssertEqual(GaplessAudioEngine.sampleRate, 16_000)
    }

    /// 真 AVAudioFile 走一遍段写入端：一段 AAC 文件写入、封口后可被 AVFoundation 读回，时长与写入帧数一致。
    func testAudioFileSinkWritesReadableAACSegments() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = AudioFileSegmentSink { seq in dir.appendingPathComponent("seg-\(seq).m4a") }
        let writer = SegmentedPCMWriter(sink: sink, sampleRate: 16_000, framesPerSegment: 16_000)
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        try writer.begin(seq: 0)
        var written = 0
        for _ in 0..<12 {
            let n = 4_000
            let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)))
            buf.frameLength = AVAudioFrameCount(n)
            let ch = try XCTUnwrap(buf.floatChannelData)[0]
            for i in 0..<n {
                let phase: Double = Double(written + i) * 2.0 * Double.pi * 440.0 / 16_000.0
                ch[i] = Float(sin(phase) * 0.3)
            }
            try writer.append(buf, frameCount: n)
            written += n
        }
        let last = try XCTUnwrap(try writer.finish())
        XCTAssertEqual(last.seq, 2)
        XCTAssertEqual(last.frames, written - 2 * 16_000)
        for seq in 0...2 {
            let file = try AVAudioFile(forReading: dir.appendingPathComponent("seg-\(seq).m4a"))
            XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
            XCTAssertEqual(file.fileFormat.channelCount, 1)
            // AAC 以 1024 帧为一包，长度允许一包以内的出入
            XCTAssertEqual(Double(file.length), 16_000, accuracy: 1_024, "第 \(seq) 段")
        }
    }
}
