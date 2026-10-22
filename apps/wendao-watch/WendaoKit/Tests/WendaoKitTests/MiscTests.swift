// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import Foundation
import XCTest

@testable import WendaoKit

final class WatchMessageTests: XCTestCase {
    func testSegmentMetadataRoundTrip() {
        let meta = WatchSegmentMetadata(
            clientSessionId: "abc-123", seq: 7, sha256: "ff", durationMs: 300_000,
            sessionStartedAt: Date(timeIntervalSince1970: 1_790_000_000.5), title: "灵感", language: "zh")
        XCTAssertEqual(WatchSegmentMetadata(dictionary: meta.dictionary), meta)
        XCTAssertEqual(WatchCredentials.kind(of: meta.dictionary), .segment)
        XCTAssertNil(WatchSessionFinished(dictionary: meta.dictionary))
    }

    func testSessionFinishedAndCredentialsRoundTrip() {
        let fin = WatchSessionFinished(
            clientSessionId: "abc", sessionStartedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2), segmentCount: 3, title: nil, language: "en")
        XCTAssertEqual(WatchSessionFinished(dictionary: fin.dictionary), fin)

        let cred = WatchCredentials(
            deviceToken: "dt", baseURL: URL(string: "https://wendao.chengqiyun.com")!,
            issuedAt: Date(timeIntervalSince1970: 9))
        XCTAssertEqual(WatchCredentials(dictionary: cred.dictionary), cred)
        let revoked = WatchCredentials(deviceToken: nil, baseURL: cred.baseURL, issuedAt: cred.issuedAt)
        XCTAssertNil(WatchCredentials(dictionary: revoked.dictionary)?.deviceToken)
    }

    func testRejectsMalformedDictionaries() {
        XCTAssertNil(WatchSegmentMetadata(dictionary: ["kind": "segment", "seq": 1]))
        XCTAssertNil(WatchCredentials(dictionary: [:]))
    }
}

final class DigestTests: XCTestCase {
    func testKnownVectors() {
        XCTAssertEqual(
            FileDigest.sha256Hex(of: Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(
            FileDigest.sha256Hex(of: Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(
            FileDigest.sha256Hex(of: Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    func testFileDigestMatchesInMemoryAcrossChunks() throws {
        let url = try makeTempDirectory().appendingPathComponent("big.bin")
        let data = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try data.write(to: url)
        XCTAssertEqual(try FileDigest.sha256Hex(of: url), FileDigest.sha256Hex(of: data))
        let million = Data(repeating: UInt8(ascii: "a"), count: 1_000_000)
        XCTAssertEqual(
            FileDigest.sha256Hex(of: million), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }
}

final class TokenStoreTests: XCTestCase {
    func testInMemoryStore() throws {
        let s = InMemoryTokenStore()
        XCTAssertNil(try s.readToken())
        try s.writeToken("a")
        XCTAssertEqual(try s.readToken(), "a")
        try s.deleteToken()
        XCTAssertNil(try s.readToken())
    }
}

@MainActor
final class RecordingCommandCenterTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "wendao.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testPendingCommandDeliveredOnRegister() async {
        let center = RecordingCommandCenter(defaults: makeDefaults())
        let t0 = Date(timeIntervalSince1970: 1000)
        await center.submit(.start, now: t0)
        let received = Box<[RecordingCommand]>([])
        await center.register({ received.value.append($0) }, now: t0.addingTimeInterval(5))
        XCTAssertEqual(received.value, [.start])
        await center.submit(.stop)
        XCTAssertEqual(received.value, [.start, .stop])
    }

    func testStalePendingCommandIsDropped() async {
        let center = RecordingCommandCenter(defaults: makeDefaults())
        let t0 = Date(timeIntervalSince1970: 1000)
        await center.submit(.start, now: t0)
        let received = Box<[RecordingCommand]>([])
        await center.register({ received.value.append($0) }, now: t0.addingTimeInterval(3600))
        XCTAssertEqual(received.value, [])
    }

    func testStatusSnapshotRoundTrip() {
        let d = makeDefaults()
        XCTAssertEqual(RecordingStatusSnapshot.load(from: d), .idle)
        let snap = RecordingStatusSnapshot(
            isRecording: true, startedAt: Date(timeIntervalSince1970: 1_790_000_000), pendingSegments: 2,
            updatedAt: Date(timeIntervalSince1970: 1_790_000_100))
        snap.save(to: d)
        XCTAssertEqual(RecordingStatusSnapshot.load(from: d), snap)
    }
}

@MainActor
final class Box<T> {
    var value: T
    init(_ v: T) { value = v }
}

final class SessionDisplayStateTests: XCTestCase {
    private func manifest(finished: Bool, source: RecordingSource = .phone, uploaded: [Bool]) -> SessionManifest {
        var m = SessionManifest(
            startedAt: Date(timeIntervalSince1970: 0), source: source,
            finishedAt: finished ? Date(timeIntervalSince1970: 600) : nil)
        for (i, u) in uploaded.enumerated() {
            m.upsert(SegmentEntry(seq: i, path: "seg-\(i).m4a", sha256: "x", durationMs: 1000, uploaded: u))
        }
        return m
    }

    private func status(_ s: MinuteProcessingStatus, progress: [Double] = []) -> MinuteStatus {
        MinuteStatus(
            id: "m", status: s, errorMessage: s == .failed ? "引擎错误" : nil, durationMs: 0, title: "",
            jobs: progress.enumerated().map {
                MinuteJob(id: "\($0.offset)", stage: "ASR", status: "RUNNING", progress: $0.element, errorMessage: nil)
            })
    }

    func testDerivesAllFiveStates() {
        let m = manifest(finished: true, uploaded: [true, false])
        XCTAssertEqual(
            SessionDisplayState.derive(manifest: m, job: nil, minute: nil, isActiveRecording: true).label, "录制中")

        var job = UploadJob(clientSessionId: m.clientSessionId, now: Date())
        let uploading = SessionDisplayState.derive(manifest: m, job: job, minute: nil, isActiveRecording: false)
        XCTAssertEqual(uploading, .uploading(uploaded: 1, total: 2, retryMessage: nil))
        XCTAssertEqual(uploading.label, "上传中")

        job.phase = .done
        let t = SessionDisplayState.derive(
            manifest: m, job: job, minute: status(.transcribing, progress: [1, 0.5]), isActiveRecording: false)
        XCTAssertEqual(t.label, "转写中")
        XCTAssertEqual(t.detail, "转写中 75%")
        XCTAssertEqual(
            SessionDisplayState.derive(manifest: m, job: job, minute: status(.ready), isActiveRecording: false), .completed)
        XCTAssertEqual(
            SessionDisplayState.derive(manifest: m, job: job, minute: status(.failed), isActiveRecording: false),
            .failed("引擎错误"))

        job.phase = .corrupted
        job.lastError = "坏了"
        XCTAssertEqual(
            SessionDisplayState.derive(manifest: m, job: job, minute: nil, isActiveRecording: false), .failed("坏了"))
    }

    func testWatchSessionStillRecordingOnPhone() {
        let m = manifest(finished: false, source: .watch, uploaded: [true])
        XCTAssertEqual(SessionDisplayState.derive(manifest: m, job: nil, minute: nil, isActiveRecording: false), .recording)
    }

    func testDurationText() {
        XCTAssertEqual(DurationText.clock(ms: 0), "0:00")
        XCTAssertEqual(DurationText.clock(ms: 754_000), "12:34")
        XCTAssertEqual(DurationText.clock(ms: 3_723_000), "1:02:03")
    }
}
