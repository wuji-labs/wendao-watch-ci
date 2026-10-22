// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import Foundation
import XCTest

@testable import WendaoKit

/// 内存里的段写入端：把每段收到的样本原样留下，供断言「一帧不丢、不重、不乱序」。
private final class MemorySink: PCMSegmentSink {
    typealias Buffer = [Float]

    var segments: [Int: [Float]] = [:]
    var openOrder: [Int] = []
    var closed: [(seq: Int, frames: Int)] = []
    private(set) var current: Int?

    func openSegment(seq: Int) throws {
        XCTAssertNil(current, "上一段未封口就开了新段")
        XCTAssertNil(segments[seq], "同一序号被打开两次")
        current = seq
        segments[seq] = []
        openOrder.append(seq)
    }

    func write(_ buffer: [Float], offset: Int, count: Int) throws {
        let seq = try XCTUnwrap(current, "没有打开的段")
        segments[seq]!.append(contentsOf: buffer[offset..<(offset + count)])
    }

    func closeSegment(seq: Int, frames: Int) throws {
        XCTAssertEqual(current, seq)
        XCTAssertEqual(segments[seq]?.count, frames, "封口时报告的帧数与实际写入不符")
        closed.append((seq, frames))
        current = nil
    }
}

/// 可复现的伪随机数（线性同余），让「随机」缓冲长度每次都一样。
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

/// 合成 PCM：每个样本的值由其全局序号唯一决定（正弦 + 序号编码），任何丢帧、重帧、错位都会让拼接结果对不上。
private func syntheticPCM(from start: Int, count: Int) -> [Float] {
    (start..<(start + count)).map { (i: Int) -> Float in
        let phase: Double = Double(i) * 2.0 * Double.pi * 440.0 / 16_000.0
        let tone: Float = Float(sin(phase) * 0.5)
        let tag: Float = Float(i % 1000) * 1e-6
        return tone + tag
    }
}

final class GaplessSegmentWriterTests: XCTestCase {
    func testSegmentsConserveEverySampleAcrossBoundaries() throws {
        let sampleRate = 16_000.0
        let framesPerSegment = 16_000 * 2  // 单测里 2 秒一段（真机 5 分钟），切点逻辑相同
        let sink = MemorySink()
        let writer = SegmentedPCMWriter(sink: sink, sampleRate: sampleRate, framesPerSegment: framesPerSegment)
        var rotations: [(ClosedSegment, Int)] = []
        writer.onRotate = { closed, opened in rotations.append((closed, opened)) }
        try writer.begin(seq: 3)

        var rng = SeededGenerator(state: 2026)
        var input: [Float] = []
        // 模拟 tap 回调：长度不规则（含 1 帧、恰好跨越多个段的超大块）
        let sizes = (0..<160).map { _ in Int.random(in: 1...4_800, using: &rng) } + [1, framesPerSegment * 2 + 17, 3]
        for n in sizes {
            let buf = syntheticPCM(from: input.count, count: n)
            input.append(contentsOf: buf)
            try writer.append(buf, frameCount: n)
        }
        let last = try XCTUnwrap(try writer.finish())

        // 样本守恒：各段样本数之和 == 输入样本数，且按序拼接后与输入逐样本相同
        let seqs = sink.openOrder
        XCTAssertEqual(seqs, Array(3..<(3 + seqs.count)), "序号连续递增")
        let total = seqs.reduce(0) { $0 + sink.segments[$1]!.count }
        XCTAssertEqual(total, input.count)
        XCTAssertEqual(Int(writer.totalFrames), input.count)
        XCTAssertEqual(seqs.flatMap { sink.segments[$0]! }, input)

        // 除最后一段外每段恰好满长；最后一段是余数
        for seq in seqs.dropLast() {
            XCTAssertEqual(sink.segments[seq]!.count, framesPerSegment, "第 \(seq) 段不满长")
        }
        XCTAssertEqual(last.seq, seqs.last)
        XCTAssertEqual(last.frames, input.count - framesPerSegment * (seqs.count - 1))
        XCTAssertGreaterThan(last.frames, 0)

        // 每次换段都回调，带出被封口段的精确时长
        XCTAssertEqual(rotations.map { $0.1 }, Array(seqs.dropFirst()))
        XCTAssertTrue(rotations.allSatisfy { $0.0.frames == framesPerSegment && $0.0.durationMs == 2_000 })
        XCTAssertEqual(sink.closed.map { $0.seq }, seqs)
    }

    func testExactBoundaryDoesNotCreateEmptySegment() throws {
        let sink = MemorySink()
        let writer = SegmentedPCMWriter(sink: sink, sampleRate: 16_000, framesPerSegment: 100)
        try writer.begin(seq: 0)
        try writer.append(syntheticPCM(from: 0, count: 100), frameCount: 100)
        // 恰好写满：还不换段（惰性），停止时也不会多出空段
        XCTAssertEqual(sink.openOrder, [0])
        let last = try XCTUnwrap(try writer.finish())
        XCTAssertEqual(last, ClosedSegment(seq: 0, frames: 100, sampleRate: 16_000))
        XCTAssertEqual(sink.openOrder, [0])
    }

    func testBoundaryInsideOneBufferSplitsAtExactFrame() throws {
        let sink = MemorySink()
        let writer = SegmentedPCMWriter(sink: sink, sampleRate: 16_000, framesPerSegment: 100)
        try writer.begin(seq: 0)
        let a = syntheticPCM(from: 0, count: 70)
        let b = syntheticPCM(from: 70, count: 60)
        try writer.append(a, frameCount: 70)
        try writer.append(b, frameCount: 60)
        try writer.finish()
        XCTAssertEqual(sink.segments[0], a + Array(b[0..<30]))
        XCTAssertEqual(sink.segments[1], Array(b[30..<60]))
    }

    func testFinishRightAfterBeginReportsZeroFrames() throws {
        let sink = MemorySink()
        let writer = SegmentedPCMWriter(sink: sink, sampleRate: 16_000, framesPerSegment: 100)
        try writer.begin(seq: 5)
        XCTAssertEqual(try writer.finish(), ClosedSegment(seq: 5, frames: 0, sampleRate: 16_000))
        XCTAssertNil(try writer.finish(), "重复结束无副作用")
    }

    func testCutterPlanIsContiguous() {
        var cutter = GaplessSegmentCutter(framesPerSegment: 10)
        XCTAssertEqual(
            cutter.split(frameCount: 25),
            [
                .init(startsNewSegment: false, offset: 0, count: 10),
                .init(startsNewSegment: true, offset: 10, count: 10),
                .init(startsNewSegment: true, offset: 20, count: 5)
            ])
        XCTAssertEqual(cutter.split(frameCount: 0), [])
        XCTAssertEqual(cutter.split(frameCount: 5), [.init(startsNewSegment: false, offset: 0, count: 5)])
        XCTAssertEqual(cutter.split(frameCount: 1), [.init(startsNewSegment: true, offset: 0, count: 1)])
        XCTAssertEqual(cutter.totalFrames, 31)
    }

    func testClosedSegmentDurationFromFrames() {
        XCTAssertEqual(ClosedSegment(seq: 0, frames: 16_000 * 300, sampleRate: 16_000).durationMs, 300_000)
        XCTAssertEqual(ClosedSegment(seq: 0, frames: 8, sampleRate: 16_000).durationMs, 1)
        XCTAssertEqual(ClosedSegment(seq: 0, frames: 7, sampleRate: 16_000).durationMs, 0)
    }
}

final class MarksAndGapsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func makePolicy(_ source: RecordingSource = .watch) throws -> SegmentRecorderPolicy {
        SegmentRecorderPolicy(store: ManifestStore(root: try makeTempDirectory()), localSource: source)
    }

    func testMarksAreWrittenToManifestAndSurviveReload() throws {
        let policy = try makePolicy()
        var m = try policy.beginSession(startedAt: start)
        try policy.addMark(.tap, at: start.addingTimeInterval(12.3456), in: &m)
        try policy.addMark(.actionButton, at: start.addingTimeInterval(400), in: &m)
        // 时钟回拨等乱序写入：仍按时间先后存放
        try policy.addMark(.doubleTap, at: start.addingTimeInterval(60), in: &m)
        try policy.addMark(.tap, at: start.addingTimeInterval(-5), in: &m)

        let expected = [
            RecordingMark(atMs: 0, source: .tap),
            RecordingMark(atMs: 12_346, source: .tap),
            RecordingMark(atMs: 60_000, source: .doubleTap),
            RecordingMark(atMs: 400_000, source: .actionButton)
        ]
        XCTAssertEqual(m.marks, expected)
        XCTAssertEqual(try policy.store.load(m.clientSessionId).marks, expected)

        // 收尾后不再接受标记
        try policy.finishSession(&m, at: start.addingTimeInterval(500))
        XCTAssertNil(try policy.addMark(.tap, at: start.addingTimeInterval(501), in: &m))
        XCTAssertEqual(try policy.store.load(m.clientSessionId).marks.count, 4)
    }

    func testManifestJSONCarriesTimelineAndOldManifestsDecodeEmpty() throws {
        let policy = try makePolicy()
        var m = try policy.beginSession(startedAt: start)
        try policy.addMark(.doubleTap, at: start.addingTimeInterval(1), in: &m)
        try policy.beginGap(at: start.addingTimeInterval(2), in: &m)
        let raw = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: policy.store.manifestURL(m.clientSessionId)))
                as? [String: Any])
        let marks = try XCTUnwrap(raw["marks"] as? [[String: Any]])
        XCTAssertEqual(marks.first?["atMs"] as? Int, 1_000)
        XCTAssertEqual(marks.first?["source"] as? String, "doubleTap")
        XCTAssertEqual(raw["openGapStartMs"] as? Int, 2_000)

        // W2 时代的清单没有这些键：解码为空，不报错
        let legacy = #"{"version":1,"clientSessionId":"abc","startedAt":"2026-10-21T08:00:00.000Z","language":"zh","source":"watch","segments":[]}"#
        let decoded = try WendaoJSON.decoder().decode(SessionManifest.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.marks, [])
        XCTAssertEqual(decoded.gaps, [])
        XCTAssertNil(decoded.openGapStartMs)
    }

    func testGapIsRecordedFromInterruptionBeginToResume() throws {
        let policy = try makePolicy()
        var m = try policy.beginSession(startedAt: start)
        try policy.beginGap(at: start.addingTimeInterval(30), in: &m)
        // 重复的「开始」（例如媒体服务重置紧跟来电）不覆盖最早的开始时刻
        try policy.beginGap(at: start.addingTimeInterval(31), in: &m)
        XCTAssertEqual(m.openGapStartMs, 30_000)
        let gap = try XCTUnwrap(try policy.endGap(at: start.addingTimeInterval(41.5), in: &m))
        XCTAssertEqual(gap, RecordingGap(startMs: 30_000, endMs: 41_500))
        XCTAssertEqual(gap.durationMs, 11_500)
        XCTAssertNil(m.openGapStartMs)
        XCTAssertNil(try policy.endGap(at: start.addingTimeInterval(50), in: &m), "没有进行中的中断时不记")

        try policy.addGap(from: start.addingTimeInterval(10), to: start.addingTimeInterval(10.12), in: &m)
        XCTAssertNil(try policy.addGap(from: start.addingTimeInterval(20), to: start.addingTimeInterval(20), in: &m))
        let reloaded = try policy.store.load(m.clientSessionId)
        XCTAssertEqual(reloaded.gaps, [RecordingGap(startMs: 10_000, endMs: 10_120), gap])
    }

    func testStoppingDuringInterruptionDropsTrailingOpenGap() throws {
        let policy = try makePolicy()
        var m = try policy.beginSession(startedAt: start)
        try policy.beginGap(at: start.addingTimeInterval(5), in: &m)
        try policy.endGap(at: start.addingTimeInterval(7), in: &m)
        try policy.beginGap(at: start.addingTimeInterval(20), in: &m)
        try policy.finishSession(&m, at: start.addingTimeInterval(25))
        let loaded = try policy.store.load(m.clientSessionId)
        XCTAssertEqual(loaded.gaps, [RecordingGap(startMs: 5_000, endMs: 7_000)])
        XCTAssertNil(loaded.openGapStartMs)
    }

    func testRecoveryKeepsMarksAndClosedGapsAndCountsGapsInFinishTime() async throws {
        let policy = try makePolicy()
        var m = try policy.beginSession(startedAt: start)
        let (e0, url0) = try policy.openSegment(in: &m)
        try writeFakeAudio(url0, seq: e0.seq)
        try policy.sealSegment(seq: e0.seq, durationMs: 60_000, in: &m)
        try policy.addMark(.tap, at: start.addingTimeInterval(15), in: &m)
        try policy.beginGap(at: start.addingTimeInterval(60), in: &m)
        try policy.endGap(at: start.addingTimeInterval(80), in: &m)
        let (e1, url1) = try policy.openSegment(in: &m)
        try writeFakeAudio(url1, seq: e1.seq)
        try policy.sealSegment(seq: e1.seq, durationMs: 30_000, in: &m)
        try policy.addMark(.actionButton, at: start.addingTimeInterval(95), in: &m)
        // 进程死在又一次打断里
        try policy.beginGap(at: start.addingTimeInterval(110), in: &m)

        let reports = await policy.recover(probe: { _ in nil }, now: start.addingTimeInterval(3600))
        XCTAssertEqual(reports.map(\.closedSession), [true])
        let r = try policy.store.load(m.clientSessionId)
        XCTAssertEqual(r.marks.map(\.atMs), [15_000, 95_000])
        XCTAssertEqual(r.gaps, [RecordingGap(startMs: 60_000, endMs: 80_000)])
        XCTAssertNil(r.openGapStartMs)
        // 墙钟收尾 = 90 秒音频 + 20 秒中断
        XCTAssertEqual(r.finishedAt, start.addingTimeInterval(110))
        XCTAssertTrue(r.isReadyToFinalize)
    }

    func testRegisterSegmentIsIdempotent() throws {
        let policy = try makePolicy()
        var m = try policy.beginSession(startedAt: start)
        let a = try policy.registerSegment(seq: 0, in: &m)
        let url = policy.store.fileURL(for: a, in: m.clientSessionId)
        try writeFakeAudio(url, seq: 0)
        try policy.sealSegment(seq: 0, durationMs: 1_000, in: &m)
        let again = try policy.registerSegment(seq: 0, in: &m)
        XCTAssertNotNil(again.sha256, "已封口的段不会被重新登记覆盖")
        try policy.registerSegment(seq: 1, in: &m)
        XCTAssertEqual(m.segments.map(\.seq), [0, 1])
        XCTAssertEqual(policy.nextSeq(in: m), 2)
    }

    func testPhoneAdoptsTimelineFromWatchFinishedMessage() throws {
        let phone = try makePolicy(.phone)
        let info = WatchSessionFinished(
            clientSessionId: "0f0f0f0f-0000-4000-8000-000000000001", sessionStartedAt: start,
            finishedAt: start.addingTimeInterval(600), segmentCount: 2, title: nil, language: "zh",
            marks: [RecordingMark(atMs: 42_000, source: .doubleTap)],
            gaps: [RecordingGap(startMs: 100_000, endMs: 103_000)])
        try phone.markSessionFinished(info)
        let m = try phone.store.load(info.clientSessionId)
        XCTAssertEqual(m.marks, info.marks)
        XCTAssertEqual(m.gaps, info.gaps)
    }

    func testFinalizeCarriesMarksAndGapsFromManifest() async throws {
        let root = try makeTempDirectory()
        let policy = SegmentRecorderPolicy(store: ManifestStore(root: root), localSource: .watch)
        var m = try recordSession(policy: policy, count: 2, finished: false, startedAt: start)
        try policy.addMark(.actionButton, at: start.addingTimeInterval(321), in: &m)
        try policy.addMark(.tap, at: start.addingTimeInterval(7), in: &m)
        try policy.beginGap(at: start.addingTimeInterval(300), in: &m)
        try policy.endGap(at: start.addingTimeInterval(304), in: &m)
        try policy.finishSession(&m, at: start.addingTimeInterval(700))

        let backend = FakeBackend()
        let queue = UploadQueue(
            store: policy.store, backend: backend, stateURL: root.appendingPathComponent("q.json"))
        await queue.enqueue(m.clientSessionId)
        let summary = await queue.runOnce()
        XCTAssertEqual(summary.finalized, [m.clientSessionId])
        let inputs = await backend.finalizeInputs
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(inputs[0].expectedSegments, 2)
        XCTAssertEqual(
            inputs[0].marks, [RecordingMark(atMs: 7_000, source: .tap), RecordingMark(atMs: 321_000, source: .actionButton)])
        XCTAssertEqual(inputs[0].gaps, [RecordingGap(startMs: 300_000, endMs: 304_000)])

        // 编码形状与服务端契约一致
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: WendaoJSON.encoder().encode(inputs[0])) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["sessionId", "expectedSegments", "marks", "gaps"])
    }

    func testFinalizeInputClampsToContractLimit() {
        let many = (0..<(SessionTimeline.maxEntries + 5)).map { RecordingMark(atMs: $0, source: .tap) }
        let input = RecordingFinalizeInput(sessionId: "s", expectedSegments: 1, marks: many.reversed())
        XCTAssertEqual(input.marks.count, SessionTimeline.maxEntries)
        XCTAssertEqual(input.marks.first?.atMs, 0)
        XCTAssertEqual(input.gaps, [])
    }
}

final class SessionTimelineTests: XCTestCase {
    func testAudioOffsetSubtractsEarlierGaps() {
        let gaps = [RecordingGap(startMs: 10_000, endMs: 15_000), RecordingGap(startMs: 30_000, endMs: 32_000)]
        XCTAssertEqual(SessionTimeline.audioOffsetMs(forWallMs: 5_000, gaps: gaps), 5_000)
        XCTAssertEqual(SessionTimeline.audioOffsetMs(forWallMs: 12_000, gaps: gaps), 10_000, "落在中断里归到中断处")
        XCTAssertEqual(SessionTimeline.audioOffsetMs(forWallMs: 20_000, gaps: gaps), 15_000)
        XCTAssertEqual(SessionTimeline.audioOffsetMs(forWallMs: 40_000, gaps: gaps), 33_000)
    }

    func testAnnotationsSortedAndHideMillisecondGlitches() {
        let items = SessionTimeline.annotations(
            marks: [RecordingMark(atMs: 20_000, source: .tap), RecordingMark(atMs: 2_000, source: .actionButton)],
            gaps: [RecordingGap(startMs: 10_000, endMs: 14_400), RecordingGap(startMs: 1_000, endMs: 1_150)])
        XCTAssertEqual(
            items,
            [
                .init(kind: .mark(.actionButton), audioMs: 1_850),
                .init(kind: .gap(durationMs: 4_400), audioMs: 9_850),
                .init(kind: .mark(.tap), audioMs: 15_450)
            ])
        XCTAssertEqual(SessionTimeline.gapSeconds(4_400), 4)
        XCTAssertEqual(SessionTimeline.gapSeconds(1_000), 1)
        XCTAssertEqual(SessionTimeline.gapSeconds(200), 1)
    }

    func testWallOffsetNeverNegative() {
        let s = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(SessionTimeline.wallOffsetMs(at: Date(timeIntervalSince1970: 99), sessionStartedAt: s), 0)
        XCTAssertEqual(SessionTimeline.wallOffsetMs(at: Date(timeIntervalSince1970: 100.0026), sessionStartedAt: s), 3)
    }

    func testMinuteDetailDecodesTimelineAndToleratesUnknownSources() throws {
        let payload = #"""
            {"minute":{"id":"m","token":"t","title":"","status":"READY","durationMs":0},"speakers":[],"segments":[],"summary":null,"chapters":[],"todos":[],
             "marks":[{"atMs":5000,"source":"doubleTap"},{"atMs":6000,"source":"futureSource"}],
             "gaps":[{"startMs":1000,"endMs":4000}]}
            """#
        let d = try WendaoJSON.decoder().decode(MinuteDetail.self, from: Data(payload.utf8))
        XCTAssertEqual(d.marks, [RecordingMark(atMs: 5_000, source: .doubleTap)])
        XCTAssertEqual(d.gaps, [RecordingGap(startMs: 1_000, endMs: 4_000)])
        XCTAssertEqual(
            d.timelineAnnotations,
            [.init(kind: .gap(durationMs: 3_000), audioMs: 1_000), .init(kind: .mark(.doubleTap), audioMs: 2_000)])

        let withText = #"""
            {"minute":{"id":"m","token":"t","title":"","status":"READY","durationMs":0},"speakers":[{"id":"a","displayName":"甲","orderIndex":0}],
             "segments":[{"id":"g1","speakerId":"a","startMs":0,"endMs":4000,"text":"开场。","orderIndex":0},
                         {"id":"g2","speakerId":null,"startMs":4000,"endMs":9000,"text":"报价改到九折。","orderIndex":1}],
             "summary":null,"chapters":[],"todos":[],
             "marks":[{"atMs":8500,"source":"tap"},{"atMs":30000,"source":"actionButton"}],
             "gaps":[{"startMs":3000,"endMs":5000}]}
            """#
        let t = try WendaoJSON.decoder().decode(MinuteDetail.self, from: Data(withText.utf8))
        // 中断落在第一段话里（音频 3000），标记 8500→音频 6500 落在第二段话里，30000→28000 在全部话之后
        XCTAssertEqual(t.transcriptRows.map(\.id), ["note-0", "turn-g1", "note-1", "turn-g2", "note-2"])
        XCTAssertEqual(t.turn(atAudioMs: 6_500)?.text, "报价改到九折。")
        XCTAssertEqual(t.turn(atAudioMs: 28_000)?.id, "g2", "超出文字稿末尾时取最后一段")

        let old = #"{"minute":{"id":"m","token":"t","title":"","status":"READY","durationMs":0},"speakers":[],"segments":[],"summary":null,"chapters":[],"todos":[]}"#
        let o = try WendaoJSON.decoder().decode(MinuteDetail.self, from: Data(old.utf8))
        XCTAssertEqual(o.marks, [])
        XCTAssertEqual(o.gaps, [])
    }
}
