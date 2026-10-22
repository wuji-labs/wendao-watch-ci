// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import Foundation

/// 录音来源设备。
public enum RecordingSource: String, Codable, Sendable {
    case watch
    case phone
}

/// 单个分段在清单中的记录。
///
/// `sha256 == nil` 表示该段仍在录制（或录制中途进程被杀，等待恢复）。
public struct SegmentEntry: Codable, Sendable, Equatable {
    public var seq: Int
    /// 相对会话目录的文件名。
    public var path: String
    public var sha256: String?
    public var durationMs: Int?
    /// 服务端已确认收到（以 `recording.status` 为准）。
    public var uploaded: Bool
    /// 手表端：已经由 WatchConnectivity 成功交给 iPhone。
    public var transferred: Bool
    /// 不可上传：文件损坏，或服务端以 409 判定内容与已收分段冲突。
    public var corrupted: Bool

    public init(
        seq: Int, path: String, sha256: String? = nil, durationMs: Int? = nil,
        uploaded: Bool = false, transferred: Bool = false, corrupted: Bool = false
    ) {
        self.seq = seq
        self.path = path
        self.sha256 = sha256
        self.durationMs = durationMs
        self.uploaded = uploaded
        self.transferred = transferred
        self.corrupted = corrupted
    }

    /// 已经封口、内容确定、可以上传的分段。
    public var isSealed: Bool { sha256 != nil && !corrupted }

    private enum CodingKeys: String, CodingKey {
        case seq, path, sha256, durationMs, uploaded, transferred, corrupted
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decode(Int.self, forKey: .seq)
        path = try c.decode(String.self, forKey: .path)
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256)
        durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs)
        uploaded = try c.decodeIfPresent(Bool.self, forKey: .uploaded) ?? false
        transferred = try c.decodeIfPresent(Bool.self, forKey: .transferred) ?? false
        corrupted = try c.decodeIfPresent(Bool.self, forKey: .corrupted) ?? false
    }
}

/// 一次录音会话的清单，落盘为会话目录下的 `manifest.json`。
public struct SessionManifest: Codable, Sendable, Equatable, Identifiable {
    public static let currentVersion = 1

    public var version: Int
    /// 客户端生成的 UUID（小写），即服务端 `recording.begin` 的幂等键。
    public var clientSessionId: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var title: String?
    public var language: String
    public var source: RecordingSource
    public var segments: [SegmentEntry]
    /// 进程崩溃后由恢复流程收尾。
    public var recoveredAfterCrash: Bool
    /// 录音端声明的分段总数（手表结束时告知 iPhone）；本机录音为 nil，以封口分段为准。
    public var expectedSegmentCount: Int?
    /// 「标记此刻」，按时间先后。
    public var marks: [RecordingMark]
    /// 已结束的录音中断，按时间先后。
    public var gaps: [RecordingGap]
    /// 正在进行中的中断的开始时刻（相对会话起点毫秒）；没有中断时为 nil。
    public var openGapStartMs: Int?

    public var id: String { clientSessionId }

    public init(
        clientSessionId: String = UUID().uuidString.lowercased(),
        startedAt: Date,
        title: String? = nil,
        language: String = "zh",
        source: RecordingSource,
        segments: [SegmentEntry] = [],
        finishedAt: Date? = nil
    ) {
        self.version = Self.currentVersion
        self.clientSessionId = clientSessionId
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.title = title
        self.language = language
        self.source = source
        self.segments = segments
        self.recoveredAfterCrash = false
        self.expectedSegmentCount = nil
        self.marks = []
        self.gaps = []
        self.openGapStartMs = nil
    }

    private enum CodingKeys: String, CodingKey {
        case version, clientSessionId, startedAt, finishedAt, title, language, source, segments,
            recoveredAfterCrash, expectedSegmentCount, marks, gaps, openGapStartMs
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        clientSessionId = try c.decode(String.self, forKey: .clientSessionId)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "zh"
        source = try c.decodeIfPresent(RecordingSource.self, forKey: .source) ?? .phone
        segments = try c.decodeIfPresent([SegmentEntry].self, forKey: .segments) ?? []
        recoveredAfterCrash = try c.decodeIfPresent(Bool.self, forKey: .recoveredAfterCrash) ?? false
        expectedSegmentCount = try c.decodeIfPresent(Int.self, forKey: .expectedSegmentCount)
        marks = try c.decodeIfPresent([RecordingMark].self, forKey: .marks) ?? []
        gaps = try c.decodeIfPresent([RecordingGap].self, forKey: .gaps) ?? []
        openGapStartMs = try c.decodeIfPresent(Int.self, forKey: .openGapStartMs)
    }

    public var isFinished: Bool { finishedAt != nil }

    /// 封口且未损坏的分段，按序号升序。
    public var sealedSegments: [SegmentEntry] {
        segments.filter(\.isSealed).sorted { $0.seq < $1.seq }
    }

    public var totalDurationMs: Int {
        sealedSegments.reduce(0) { $0 + ($1.durationMs ?? 0) }
    }

    /// 封口分段是否恰好是 0..<n 的连续序号。终结时服务端按 `expectedSegments = n` 校验。
    public var sealedSegmentsAreContiguous: Bool {
        sealedSegments.enumerated().allSatisfy { $0.offset == $0.element.seq }
    }

    /// 可以向服务端终结：已收尾、无录制中分段、序号连续，且收齐了录音端声明的段数。
    public var isReadyToFinalize: Bool {
        guard isFinished, !sealedSegments.isEmpty, sealedSegmentsAreContiguous else { return false }
        guard !segments.contains(where: { $0.sha256 == nil && !$0.corrupted }) else { return false }
        if let expected = expectedSegmentCount { return sealedSegments.count >= expected }
        return true
    }

    public func segment(seq: Int) -> SegmentEntry? {
        segments.first { $0.seq == seq }
    }

    public mutating func updateSegment(seq: Int, _ body: (inout SegmentEntry) -> Void) {
        guard let i = segments.firstIndex(where: { $0.seq == seq }) else { return }
        body(&segments[i])
    }

    public mutating func upsert(_ entry: SegmentEntry) {
        if let i = segments.firstIndex(where: { $0.seq == entry.seq }) {
            segments[i] = entry
        } else {
            segments.append(entry)
            segments.sort { $0.seq < $1.seq }
        }
    }
}
