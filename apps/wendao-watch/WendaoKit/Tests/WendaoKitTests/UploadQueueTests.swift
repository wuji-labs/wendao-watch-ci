// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import Foundation
import XCTest

@testable import WendaoKit

final class UploadQueueTests: XCTestCase {
    private struct Fixture {
        let policy: SegmentRecorderPolicy
        let backend: FakeBackend
        let clock: TestClock
        let stateURL: URL

        func makeQueue() -> UploadQueue {
            UploadQueue(
                store: policy.store, backend: backend, stateURL: stateURL,
                retry: RetryPolicy(baseDelay: 2, multiplier: 2, maxDelay: 60, jitterRatio: 0, random: { 0 }),
                clock: clock.wendaoClock)
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = try makeTempDirectory()
        return Fixture(
            policy: SegmentRecorderPolicy(store: ManifestStore(root: root), localSource: .watch),
            backend: FakeBackend(), clock: TestClock(),
            stateURL: root.appendingPathComponent("upload-queue.json"))
    }

    func testHappyPathBeginUploadFinalize() async throws {
        let f = try makeFixture()
        let m = try recordSession(policy: f.policy, count: 3, finished: true)
        let queue = f.makeQueue()
        await queue.enqueue(m.clientSessionId)
        let summary = await queue.runOnce()

        XCTAssertEqual(summary.uploadedSegments, 3)
        XCTAssertEqual(summary.finalized, [m.clientSessionId])
        let jobOpt = await queue.job(m.clientSessionId)
        let job = try XCTUnwrap(jobOpt)
        XCTAssertEqual(job.phase, .done)
        XCTAssertEqual(job.minuteToken, "tok1")
        let calls = await f.backend.uploadCalls
        XCTAssertEqual(calls, [0, 1, 2])
        let after = try f.policy.store.load(m.clientSessionId)
        XCTAssertTrue(after.segments.allSatisfy(\.uploaded))

        // 已完成的会话不再触网
        _ = await queue.runOnce()
        let beginCalls = await f.backend.beginCalls
        XCTAssertEqual(beginCalls, 1)
    }

    func testFillsOnlyMissingSegmentsReportedByStatus() async throws {
        let f = try makeFixture()
        let m = try recordSession(policy: f.policy, count: 4, finished: true)
        // 服务端已从另一条通道（例如 iPhone 中转）收到第 0、2 段
        await f.backend.setPreloaded([
            0: try XCTUnwrap(m.segment(seq: 0)?.sha256), 2: try XCTUnwrap(m.segment(seq: 2)?.sha256)
        ])
        let queue = f.makeQueue()
        await queue.enqueue(m.clientSessionId)
        await queue.runOnce()

        let calls = await f.backend.uploadCalls
        XCTAssertEqual(calls, [1, 3])
        let phase = await queue.job(m.clientSessionId)?.phase
        XCTAssertEqual(phase, .done)
        XCTAssertTrue(try f.policy.store.load(m.clientSessionId).segments.allSatisfy(\.uploaded))
    }

    func testFinalizeMissingSegmentsTriggersReconcileAndReupload() async throws {
        let f = try makeFixture()
        let m = try recordSession(policy: f.policy, count: 3, finished: true)
        await f.backend.setDropOnFirstFinalize([1])
        let queue = f.makeQueue()
        await queue.enqueue(m.clientSessionId)
        await queue.runOnce()

        let calls = await f.backend.uploadCalls
        XCTAssertEqual(calls, [0, 1, 2, 1])
        let finalizeCalls = await f.backend.finalizeCalls
        XCTAssertEqual(finalizeCalls, 2)
        let phase = await queue.job(m.clientSessionId)?.phase
        XCTAssertEqual(phase, .done)
    }

    func testConflict409MarksCorruptedAndStops() async throws {
        let f = try makeFixture()
        let m = try recordSession(policy: f.policy, count: 3, finished: true)
        // 服务端对第 1 段返回 409（同序号已收到不同内容）
        await f.backend.setConflictOnUpload([1])
        let queue = f.makeQueue()
        await queue.enqueue(m.clientSessionId)
        await queue.runOnce()

        let jobOpt = await queue.job(m.clientSessionId)

        let job = try XCTUnwrap(jobOpt)
        XCTAssertEqual(job.phase, .corrupted)
        XCTAssertEqual(job.corruptedSeqs, [1])
        XCTAssertNotNil(job.lastError)
        let after = try f.policy.store.load(m.clientSessionId)
        XCTAssertEqual(after.segment(seq: 1)?.corrupted, true)
        XCTAssertEqual(after.segment(seq: 0)?.uploaded, true)
        let finalizeCalls = await f.backend.finalizeCalls
        XCTAssertEqual(finalizeCalls, 0)

        // 损坏的会话不再重试
        f.clock.advance(3600)
        await queue.runOnce()
        let calls = await f.backend.uploadCalls
        XCTAssertEqual(calls, [0, 1])
    }

    func testTransientFailuresBackOffExponentiallyThenSucceed() async throws {
        let f = try makeFixture()
        let m = try recordSession(policy: f.policy, count: 2, finished: true)
        await f.backend.failNext(
            "upload", with: [.transport("offline"), .server(status: 503, message: ""), .tooManyRequests("")])
        let queue = f.makeQueue()
        await queue.enqueue(m.clientSessionId)

        var s = await queue.runOnce()
        let jobFirst = await queue.job(m.clientSessionId)
        var job = try XCTUnwrap(jobFirst)
        XCTAssertEqual(job.consecutiveFailures, 1)
        XCTAssertEqual(s.nextWake, f.clock.now.addingTimeInterval(2))

        // 未到点：不处理
        f.clock.advance(1)
        s = await queue.runOnce()
        XCTAssertTrue(s.processed.isEmpty)

        f.clock.advance(1)
        s = await queue.runOnce()
        let jobNext1 = await queue.job(m.clientSessionId)
        job = try XCTUnwrap(jobNext1)
        XCTAssertEqual(job.consecutiveFailures, 2)
        XCTAssertEqual(s.nextWake, f.clock.now.addingTimeInterval(4))

        f.clock.advance(4)
        await queue.runOnce()
        let jobNext2 = await queue.job(m.clientSessionId)
        job = try XCTUnwrap(jobNext2)
        XCTAssertEqual(job.consecutiveFailures, 3)
        XCTAssertEqual(job.nextAttemptAt, f.clock.now.addingTimeInterval(8))

        f.clock.advance(8)
        await queue.runOnce()
        let jobNext3 = await queue.job(m.clientSessionId)
        job = try XCTUnwrap(jobNext3)
        XCTAssertEqual(job.phase, .done)
        XCTAssertEqual(job.consecutiveFailures, 0)
    }

    func testRetryPolicyCapsAndJitters() {
        let p = RetryPolicy(baseDelay: 2, multiplier: 2, maxDelay: 30, jitterRatio: 0.5, random: { 1 })
        XCTAssertEqual(p.delay(afterFailures: 1), 3)
        XCTAssertEqual(p.delay(afterFailures: 3), 12)
        XCTAssertEqual(p.delay(afterFailures: 20), 45)
        let noJitter = RetryPolicy(baseDelay: 2, multiplier: 2, maxDelay: 30, jitterRatio: 0, random: { 1 })
        XCTAssertEqual(noJitter.delay(afterFailures: 0), 2)
    }

    func testStatePersistsAcrossRestart() async throws {
        let f = try makeFixture()
        let m = try recordSession(policy: f.policy, count: 2, finished: true)
        await f.backend.failNext("upload", with: [.transport("offline")])
        do {
            let queue = f.makeQueue()
            await queue.enqueue(m.clientSessionId)
            await queue.runOnce()
            let job = await queue.job(m.clientSessionId)
            XCTAssertNotNil(job?.serverSessionId)
        }
        // 进程重启：新实例从状态文件恢复，沿用已建会话，不再 begin 新会话
        let restarted = f.makeQueue()
        let restoredOpt = await restarted.job(m.clientSessionId)
        let restored = try XCTUnwrap(restoredOpt)
        XCTAssertEqual(restored.consecutiveFailures, 1)
        f.clock.advance(10)
        await restarted.runOnce()
        let phase = await restarted.job(m.clientSessionId)?.phase
        XCTAssertEqual(phase, .done)
        let sessions = await f.backend.sessions.count
        XCTAssertEqual(sessions, 1)
    }

    func testUploadsSealedSegmentsWhileStillRecording() async throws {
        let f = try makeFixture()
        var m = try recordSession(policy: f.policy, count: 2, finished: false)
        let queue = f.makeQueue()
        await queue.enqueue(m.clientSessionId)
        var s = await queue.runOnce()
        XCTAssertEqual(s.uploadedSegments, 2)
        XCTAssertNil(s.nextWake)
        var finalizeCalls = await f.backend.finalizeCalls
        XCTAssertEqual(finalizeCalls, 0)
        var phase = await queue.job(m.clientSessionId)?.phase
        XCTAssertEqual(phase, .uploading)

        // 录完第 3 段并收尾
        let (e, url) = try f.policy.openSegment(in: &m)
        try writeFakeAudio(url, seq: e.seq)
        try f.policy.sealSegment(seq: e.seq, durationMs: 1000, in: &m)
        try f.policy.finishSession(&m, at: Date())
        await queue.enqueue(m.clientSessionId)
        s = await queue.runOnce()
        XCTAssertEqual(s.uploadedSegments, 1)
        finalizeCalls = await f.backend.finalizeCalls
        XCTAssertEqual(finalizeCalls, 1)
        phase = await queue.job(m.clientSessionId)?.phase
        XCTAssertEqual(phase, .done)
    }

    func testUnauthorizedPausesQueueUntilRebind() async throws {
        let f = try makeFixture()
        let a = try recordSession(policy: f.policy, count: 1, finished: true)
        let b = try recordSession(policy: f.policy, count: 1, finished: true)
        await f.backend.failNext("begin", with: [.unauthorized])
        let queue = f.makeQueue()
        await queue.enqueue(a.clientSessionId)
        await queue.enqueue(b.clientSessionId)
        let s = await queue.runOnce()
        XCTAssertTrue(s.needsAuthentication)
        XCTAssertEqual(s.processed.count, 1, "401 后同一轮不再处理其他会话")
        var begin = await f.backend.beginCalls
        XCTAssertEqual(begin, 1)

        f.clock.advance(3600)
        await queue.runOnce()
        begin = await f.backend.beginCalls
        XCTAssertEqual(begin, 1, "暂停期间不触网")

        await queue.resumeAfterAuthentication()
        await queue.runOnce()
        let pa = await queue.job(a.clientSessionId)?.phase
        let pb = await queue.job(b.clientSessionId)?.phase
        XCTAssertEqual(pa, .done)
        XCTAssertEqual(pb, .done)
    }

    func testSequenceGapFailsWithoutFinalize() async throws {
        let f = try makeFixture()
        var m = try recordSession(policy: f.policy, count: 3, finished: true)
        m.updateSegment(seq: 1) { $0.corrupted = true }
        try f.policy.store.save(m)
        let queue = f.makeQueue()
        await queue.enqueue(m.clientSessionId)
        await queue.runOnce()
        let jobOpt = await queue.job(m.clientSessionId)
        let job = try XCTUnwrap(jobOpt)
        XCTAssertEqual(job.phase, .failed)
        let finalizeCalls = await f.backend.finalizeCalls
        XCTAssertEqual(finalizeCalls, 0)
    }

    func testServerLostSessionIsRecreated() async throws {
        let f = try makeFixture()
        let m = try recordSession(policy: f.policy, count: 1, finished: true)
        await f.backend.failNext("status", with: [.notFound("")])
        let queue = f.makeQueue()
        await queue.enqueue(m.clientSessionId)
        await queue.runOnce()
        let jobFirst = await queue.job(m.clientSessionId)
        var job = try XCTUnwrap(jobFirst)
        XCTAssertNil(job.serverSessionId)
        XCTAssertEqual(job.consecutiveFailures, 1)
        f.clock.advance(5)
        await queue.runOnce()
        let jobNext4 = await queue.job(m.clientSessionId)
        job = try XCTUnwrap(jobNext4)
        XCTAssertEqual(job.phase, .done)
    }

    func testSessionFinalizedByOtherDeviceIsAdopted() async throws {
        let f = try makeFixture()
        let m = try recordSession(policy: f.policy, count: 2, finished: true)
        _ = await f.backend.preFinalize(
            clientSessionId: m.clientSessionId,
            segments: [0: try XCTUnwrap(m.segment(seq: 0)?.sha256), 1: try XCTUnwrap(m.segment(seq: 1)?.sha256)])
        let queue = f.makeQueue()
        await queue.enqueue(m.clientSessionId)
        let s = await queue.runOnce()
        XCTAssertEqual(s.finalized, [m.clientSessionId])
        let jobOpt = await queue.job(m.clientSessionId)
        let job = try XCTUnwrap(jobOpt)
        XCTAssertEqual(job.phase, .done)
        XCTAssertEqual(job.minuteToken, "by-phone")
        let uploads = await f.backend.uploadCalls
        let finalizes = await f.backend.finalizeCalls
        XCTAssertEqual(uploads, [])
        XCTAssertEqual(finalizes, 0)
    }

    func testDrainSleepsUntilNextAttempt() async throws {
        let f = try makeFixture()
        let m = try recordSession(policy: f.policy, count: 1, finished: true)
        await f.backend.failNext("upload", with: [.transport("x"), .transport("y")])
        let queue = f.makeQueue()
        await queue.enqueue(m.clientSessionId)
        let clock = f.clock
        let slept = SleepRecorder()
        await queue.drain(sleep: { seconds in
            slept.append(seconds)
            clock.advance(seconds)
        })
        XCTAssertEqual(slept.values, [2, 4])
        let phase = await queue.job(m.clientSessionId)?.phase
        XCTAssertEqual(phase, .done)
    }
}

final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TimeInterval] = []
    func append(_ v: TimeInterval) { lock.withLock { storage.append(v) } }
    var values: [TimeInterval] { lock.withLock { storage } }
}
