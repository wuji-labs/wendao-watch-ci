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
        let s = AudioSegmentRecorder.settings
        XCTAssertEqual(s[AVFormatIDKey] as? UInt32, kAudioFormatMPEG4AAC)
        XCTAssertEqual(s[AVSampleRateKey] as? Double, 16_000)
        XCTAssertEqual(s[AVNumberOfChannelsKey] as? Int, 1)
    }
}
