// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import Foundation
import XCTest

@testable import WendaoKit

final class SegmentRecorderPolicyTests: XCTestCase {
    private func makePolicy(_ source: RecordingSource = .watch) throws -> SegmentRecorderPolicy {
        SegmentRecorderPolicy(store: ManifestStore(root: try makeTempDirectory()), localSource: source)
    }

    func testFileNamingRoundTrips() throws {
        let policy = try makePolicy()
        XCTAssertEqual(policy.fileName(forSeq: 0), "seg-00000.m4a")
        XCTAssertEqual(policy.fileName(forSeq: 42), "seg-00042.m4a")
        XCTAssertEqual(policy.fileName(forSeq: 123_456), "seg-123456.m4a")
        XCTAssertEqual(policy.seq(fromFileName: "seg-00042.m4a"), 42)
        XCTAssertNil(policy.seq(fromFileName: "manifest.json"))
        XCTAssertNil(policy.seq(fromFileName: "seg-.m4a"))
        XCTAssertNil(policy.seq(fromFileName: "seg-00001.caf"))
    }

    func testRotatesEveryFiveMinutes() throws {
        let policy = try makePolicy()
        XCTAssertEqual(policy.segmentDuration, 300)
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(policy.shouldRotate(segmentStartedAt: start, now: start.addingTimeInterval(299.9)))
        XCTAssertTrue(policy.shouldRotate(segmentStartedAt: start, now: start.addingTimeInterval(300)))
    }

    func testOpenAndSealSegmentsWritesManifest() throws {
        let policy = try makePolicy()
        var m = try policy.beginSession(startedAt: Date(timeIntervalSince1970: 1_790_000_000), title: "访谈")
        let (e0, url0) = try policy.openSegment(in: &m)
        XCTAssertEqual(e0.seq, 0)
        XCTAssertNil(e0.sha256)
        // 先落清单再录音：此刻清单里已有未封口的第 0 段
        XCTAssertEqual(try policy.store.load(m.clientSessionId).segments.count, 1)

        let data = try writeFakeAudio(url0, seq: 0)
        let sealed = try XCTUnwrap(try policy.sealSegment(seq: 0, durationMs: 300_000, in: &m))
        XCTAssertEqual(sealed.sha256, FileDigest.sha256Hex(of: data))
        XCTAssertEqual(sealed.durationMs, 300_000)

        let (e1, _) = try policy.openSegment(in: &m)
        XCTAssertEqual(e1.seq, 1)
        // 第 1 段什么都没写就停了：从清单移除
        XCTAssertNil(try policy.sealSegment(seq: 1, durationMs: 0, in: &m))
        try policy.finishSession(&m, at: Date(timeIntervalSince1970: 1_790_000_300))

        let loaded = try policy.store.load(m.clientSessionId)
        XCTAssertEqual(loaded, m)
        XCTAssertEqual(loaded.segments.map(\.seq), [0])
        XCTAssertTrue(loaded.isReadyToFinalize)
        XCTAssertThrowsError(try policy.openSegment(in: &m))
    }

    func testManifestJSONUsesContractKeys() throws {
        let policy = try makePolicy()
        let m = try recordSession(policy: policy, count: 1, finished: false)
        let raw = try Data(contentsOf: policy.store.manifestURL(m.clientSessionId))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        XCTAssertEqual(obj["clientSessionId"] as? String, m.clientSessionId)
        XCTAssertEqual(obj["startedAt"] as? String, "2026-09-21T14:13:20.000Z")
        let seg = try XCTUnwrap((obj["segments"] as? [[String: Any]])?.first)
        for key in ["seq", "path", "sha256", "durationMs", "uploaded"] {
            XCTAssertNotNil(seg[key], "缺少字段 \(key)")
        }
    }

    func testRecoveryAfterCrash() async throws {
        let policy = try makePolicy(.watch)
        var m = try policy.beginSession(startedAt: Date(timeIntervalSince1970: 1_790_000_000))
        // 第 0 段正常封口
        let (_, url0) = try policy.openSegment(in: &m)
        try writeFakeAudio(url0, seq: 0)
        try policy.sealSegment(seq: 0, durationMs: 300_000, in: &m)
        // 第 1 段录到一半进程被杀：清单里未封口，文件可解析
        let (_, url1) = try policy.openSegment(in: &m)
        try writeFakeAudio(url1, seq: 1)
        // 第 2 段：文件已建但写坏（探测失败）
        let (_, url2) = try policy.openSegment(in: &m)
        try writeFakeAudio(url2, seq: 2)
        // 第 3 段：登记了但从未写入
        _ = try policy.openSegment(in: &m)
        // 清单写完之前就落盘的孤儿段文件
        let dir = policy.store.sessionDirectory(m.clientSessionId)
        try writeFakeAudio(dir.appendingPathComponent(policy.fileName(forSeq: 4)), seq: 4)

        let broken = url2
        let reports = await policy.recover(
            probe: { url in url.lastPathComponent == broken.lastPathComponent ? nil : 120_000 },
            now: Date(timeIntervalSince1970: 1_790_009_999))
        XCTAssertEqual(reports.count, 1)
        let r = try XCTUnwrap(reports.first)
        XCTAssertEqual(r.recoveredSeqs, [1])
        XCTAssertEqual(r.adoptedSeqs, [4])
        XCTAssertEqual(r.corruptedSeqs, [2])
        XCTAssertEqual(r.droppedSeqs, [3])
        XCTAssertTrue(r.closedSession)

        let after = try policy.store.load(m.clientSessionId)
        XCTAssertTrue(after.isFinished)
        XCTAssertTrue(after.recoveredAfterCrash)
        XCTAssertEqual(after.segments.map(\.seq), [0, 1, 2, 4])
        XCTAssertEqual(after.segment(seq: 1)?.durationMs, 120_000)
        XCTAssertNotNil(after.segment(seq: 1)?.sha256)
        XCTAssertEqual(after.segment(seq: 2)?.corrupted, true)
        XCTAssertEqual(after.sealedSegments.map(\.seq), [0, 1, 4])
        // 中间坏了一段，序号不连续：不能终结
        XCTAssertFalse(after.sealedSegmentsAreContiguous)
        // 收尾时间 = 开始 + 已封口时长
        XCTAssertEqual(after.finishedAt, Date(timeIntervalSince1970: 1_790_000_000 + 300 + 120 + 120))

        // 再跑一次是幂等的
        let again = await policy.recover(probe: { _ in 1 }, now: Date())
        XCTAssertTrue(again.isEmpty)
    }

    func testRecoverySkipsActiveSessionAndRemoteSessions() async throws {
        let policy = try makePolicy(.phone)
        let active = try recordSession(policy: policy, count: 1, finished: false)
        var mActive = active
        _ = try policy.openSegment(in: &mActive)

        // iPhone 上从手表收来的会话：未收尾也不由 iPhone 收尾
        let remote = SessionManifest(startedAt: Date(timeIntervalSince1970: 1), source: .watch)
        try policy.store.save(remote)

        let reports = await policy.recover(activeSessionId: active.clientSessionId, probe: { _ in 1000 }, now: Date())
        XCTAssertTrue(reports.isEmpty)
        XCTAssertFalse(try policy.store.load(remote.clientSessionId).isFinished)
        XCTAssertNil(try policy.store.load(active.clientSessionId).finishedAt)
    }

    func testImportSegmentFromWatchVerifiesDigest() throws {
        let phone = try makePolicy(.phone)
        let staging = try makeTempDirectory()
        let id = UUID().uuidString.lowercased()

        let good = staging.appendingPathComponent("a.m4a")
        let data = try writeFakeAudio(good, seq: 0)
        let meta = WatchSegmentMetadata(
            clientSessionId: id, seq: 0, sha256: FileDigest.sha256Hex(of: data), durationMs: 300_000,
            sessionStartedAt: Date(timeIntervalSince1970: 5), title: nil, language: "zh")
        let entry = try phone.importSegment(meta, stagedFile: good)
        XCTAssertFalse(entry.corrupted)
        XCTAssertTrue(entry.transferred)

        let bad = staging.appendingPathComponent("b.m4a")
        try writeFakeAudio(bad, seq: 1)
        var badMeta = meta
        badMeta.seq = 1
        badMeta.sha256 = String(repeating: "0", count: 64)
        XCTAssertTrue(try phone.importSegment(badMeta, stagedFile: bad).corrupted)

        try phone.markSessionFinished(
            WatchSessionFinished(
                clientSessionId: id, sessionStartedAt: Date(timeIntervalSince1970: 5),
                finishedAt: Date(timeIntervalSince1970: 605), segmentCount: 2, title: nil, language: "zh"))
        let m = try phone.store.load(id)
        XCTAssertEqual(m.source, .watch)
        XCTAssertEqual(m.expectedSegmentCount, 2)
        // 第 1 段损坏：未收齐，不终结
        XCTAssertFalse(m.isReadyToFinalize)

        // 手表重传正确的第 1 段后可终结
        let fixed = staging.appendingPathComponent("c.m4a")
        let fixedData = try writeFakeAudio(fixed, seq: 1)
        badMeta.sha256 = FileDigest.sha256Hex(of: fixedData)
        XCTAssertFalse(try phone.importSegment(badMeta, stagedFile: fixed).corrupted)
        XCTAssertTrue(try phone.store.load(id).isReadyToFinalize)
    }

    func testRejectsPathTraversalSessionIds() throws {
        let policy = try makePolicy()
        XCTAssertThrowsError(try policy.store.load("../../etc"))
        var meta = WatchSegmentMetadata(
            clientSessionId: "../x", seq: 0, sha256: "", durationMs: nil,
            sessionStartedAt: Date(), title: nil, language: "zh")
        meta.seq = 0
        let f = try makeTempDirectory().appendingPathComponent("f.m4a")
        try writeFakeAudio(f, seq: 0)
        XCTAssertThrowsError(try policy.importSegment(meta, stagedFile: f))
    }
}
