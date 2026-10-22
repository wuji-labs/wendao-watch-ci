// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import Foundation
import XCTest

@testable import WendaoKit

/// 每个测试一个独立临时目录。
func makeTempDirectory(_ name: String = #function) throws -> URL {
    let safe = name.filter { $0.isLetter || $0.isNumber }
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("WendaoKitTests", isDirectory: true)
        .appendingPathComponent("\(safe)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// 可手动推进的时钟。
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_790_000_000)) {
        current = start
    }

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }

    var wendaoClock: WendaoClock {
        WendaoClock { [self] in self.now }
    }
}

/// 写一个假音频文件（内容随序号不同，摘要也不同）。
@discardableResult
func writeFakeAudio(_ url: URL, seq: Int, bytes: Int = 2048) throws -> Data {
    var data = Data("WENDAO-SEG-\(seq)-".utf8)
    data.append(Data(repeating: UInt8(seq % 251), count: bytes))
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
    return data
}

/// 录完一个包含 `count` 段的会话（已封口），返回清单。
func recordSession(
    policy: SegmentRecorderPolicy, count: Int, finished: Bool, startedAt: Date = Date(timeIntervalSince1970: 1_790_000_000)
) throws -> SessionManifest {
    var m = try policy.beginSession(startedAt: startedAt, title: "周会")
    for _ in 0..<count {
        let (entry, url) = try policy.openSegment(in: &m)
        try writeFakeAudio(url, seq: entry.seq)
        try policy.sealSegment(seq: entry.seq, durationMs: 300_000, in: &m)
    }
    if finished {
        try policy.finishSession(&m, at: startedAt.addingTimeInterval(Double(count) * 300))
    }
    return m
}

/// 录音后端桩：内存里模拟 W1 的会话、分段幂等与 409、终结缺段。
actor FakeBackend: RecordingBackend {
    struct Session {
        var clientSessionId: String
        var segments: [Int: String] = [:]
        var finalized: RecordingFinalizeOutput?
    }

    var sessions: [String: Session] = [:]
    var beginCalls = 0
    var statusCalls = 0
    var uploadCalls: [Int] = []
    var finalizeCalls = 0
    /// 每次终结请求的完整入参（断言 marks / gaps 随附）。
    var finalizeInputs: [RecordingFinalizeInput] = []
    /// 依次抛出的错误（每次调用消耗一个），用于模拟网络故障。
    var failures: [String: [WendaoAPIError]] = [:]
    /// 服务端预置的已收分段（模拟另一端已经传过），键为 seq，值为 sha256。
    var preloaded: [Int: String] = [:]
    /// 让服务端「丢」掉某些段一次：终结时报缺段。
    var dropOnFirstFinalize: Set<Int> = []

    func failNext(_ op: String, with errors: [WendaoAPIError]) {
        failures[op, default: []].append(contentsOf: errors)
    }

    /// 上传这些序号时返回 409。
    var conflictOnUpload: Set<Int> = []

    func setPreloaded(_ p: [Int: String]) { preloaded = p }

    /// 模拟另一端已经把同一 clientSessionId 的会话传完并终结。
    func preFinalize(clientSessionId: String, segments: [Int: String]) -> String {
        let id = UUID().uuidString.lowercased()
        var s = Session(clientSessionId: clientSessionId)
        s.segments = segments
        s.finalized = RecordingFinalizeOutput(minuteId: UUID().uuidString.lowercased(), token: "by-phone")
        sessions[id] = s
        return id
    }
    func setConflictOnUpload(_ s: Set<Int>) { conflictOnUpload = s }
    func setDropOnFirstFinalize(_ s: Set<Int>) { dropOnFirstFinalize = s }

    private func maybeFail(_ op: String) throws {
        if var list = failures[op], !list.isEmpty {
            let e = list.removeFirst()
            failures[op] = list
            throw e
        }
    }

    func beginRecording(_ input: RecordingBeginInput) async throws -> RecordingBeginOutput {
        beginCalls += 1
        try maybeFail("begin")
        if let existing = sessions.first(where: { $0.value.clientSessionId == input.clientSessionId }) {
            return RecordingBeginOutput(sessionId: existing.key)
        }
        let id = UUID().uuidString.lowercased()
        var s = Session(clientSessionId: input.clientSessionId)
        s.segments = preloaded
        sessions[id] = s
        return RecordingBeginOutput(sessionId: id)
    }

    func recordingStatus(sessionId: String) async throws -> RecordingStatusOutput {
        statusCalls += 1
        try maybeFail("status")
        guard let s = sessions[sessionId] else { throw WendaoAPIError.notFound("") }
        return RecordingStatusOutput(
            status: s.finalized == nil ? "OPEN" : "DONE", receivedSeqs: s.segments.keys.sorted(),
            minuteId: s.finalized?.minuteId, token: s.finalized?.token)
    }

    func uploadSegment(_ upload: SegmentUpload) async throws {
        uploadCalls.append(upload.seq)
        try maybeFail("upload")
        guard var s = sessions[upload.sessionId] else { throw WendaoAPIError.notFound("") }
        if s.finalized != nil { throw WendaoAPIError.sessionClosed("") }
        let actual = try FileDigest.sha256Hex(of: upload.fileURL)
        guard actual == upload.sha256 else { throw WendaoAPIError.badRequest("sha256 mismatch") }
        if conflictOnUpload.contains(upload.seq) {
            throw WendaoAPIError.conflict("hash conflict")
        }
        if let existing = s.segments[upload.seq], existing != upload.sha256 {
            throw WendaoAPIError.conflict("hash conflict")
        }
        s.segments[upload.seq] = upload.sha256
        sessions[upload.sessionId] = s
    }

    func finalizeRecording(_ input: RecordingFinalizeInput) async throws -> RecordingFinalizeOutput {
        let sessionId = input.sessionId
        let expectedSegments = input.expectedSegments
        finalizeCalls += 1
        finalizeInputs.append(input)
        try maybeFail("finalize")
        guard var s = sessions[sessionId] else { throw WendaoAPIError.notFound("") }
        if let done = s.finalized { return done }
        if !dropOnFirstFinalize.isEmpty {
            for seq in dropOnFirstFinalize { s.segments[seq] = nil }
            dropOnFirstFinalize = []
            sessions[sessionId] = s
        }
        let missing = (0..<expectedSegments).filter { s.segments[$0] == nil }
        guard missing.isEmpty else {
            throw WendaoAPIError.preconditionFailed("缺少分段 \(missing)")
        }
        let out = RecordingFinalizeOutput(minuteId: UUID().uuidString.lowercased(), token: "tok\(finalizeCalls)")
        s.finalized = out
        sessions[sessionId] = s
        return out
    }
}
