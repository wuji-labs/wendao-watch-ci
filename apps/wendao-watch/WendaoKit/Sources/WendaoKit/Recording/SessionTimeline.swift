// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import Foundation

/// 「标记此刻」的触发方式（与 `packages/miaoji-contracts/src/recording.ts` 的 `RecordingMarkSource` 一致）。
public enum RecordingMarkSource: String, Codable, Sendable, CaseIterable {
    /// 点按界面上的「标记」按钮。
    case tap
    /// watchOS 双指互点手势。
    case doubleTap
    /// Apple Watch Ultra 的 Action Button（经 App Intent）。
    case actionButton
}

/// 一个标记。`atMs` 是相对会话起点（`SessionManifest.startedAt`）的墙钟毫秒。
public struct RecordingMark: Codable, Sendable, Equatable {
    public var atMs: Int
    public var source: RecordingMarkSource

    public init(atMs: Int, source: RecordingMarkSource) {
        self.atMs = atMs
        self.source = source
    }
}

/// 一次录音中断（来电、闹钟、Siri、音频硬件重配置）。起止均为相对会话起点的墙钟毫秒，`endMs >= startMs`。
///
/// 中断期间没有声音写入分段，所以服务端拼接出的音频比墙钟短：
/// 音频位置 = 墙钟位置 − 此前全部中断的时长（见 `SessionTimeline.audioOffsetMs`）。
public struct RecordingGap: Codable, Sendable, Equatable {
    public var startMs: Int
    public var endMs: Int

    public init(startMs: Int, endMs: Int) {
        self.startMs = startMs
        self.endMs = max(startMs, endMs)
    }

    public var durationMs: Int { endMs - startMs }
}

/// 会话时间线的换算与纪要侧标注。
public enum SessionTimeline {
    /// 单次会话最多保留的标记 / 中断条数（与服务端 `RECORDING_MAX_MARKS` 一致）。
    public static let maxEntries = 10_000

    /// 相对会话起点的墙钟毫秒（不早于 0）。
    public static func wallOffsetMs(at date: Date, sessionStartedAt: Date) -> Int {
        let ms = (date.timeIntervalSince(sessionStartedAt) * 1000).rounded()
        guard ms.isFinite, ms > 0 else { return 0 }
        return Int(min(ms, Double(Int32.max) * 1000))
    }

    /// 墙钟位置换算成拼接后音频里的位置：减去此前已发生的中断时长；落在中断之中的点归到中断处。
    public static func audioOffsetMs(forWallMs wallMs: Int, gaps: [RecordingGap]) -> Int {
        var removed = 0
        for gap in gaps where gap.startMs < wallMs {
            removed += min(wallMs, gap.endMs) - gap.startMs
        }
        return max(0, wallMs - removed)
    }

    /// 纪要侧的一条标注。
    public struct Annotation: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case mark(RecordingMarkSource)
            /// 此处中断了多少毫秒。
            case gap(durationMs: Int)
        }

        public var kind: Kind
        /// 在拼接后音频（即文字稿时间轴）里的位置。
        public var audioMs: Int

        public init(kind: Kind, audioMs: Int) {
            self.kind = kind
            self.audioMs = audioMs
        }
    }

    /// 标记与中断按音频位置排序。短于 `minGapMs` 的中断（如蓝牙耳机切换引起的毫秒级重配置）不显示。
    public static func annotations(
        marks: [RecordingMark], gaps: [RecordingGap], minGapMs: Int = 1000
    ) -> [Annotation] {
        let sortedGaps = gaps.sorted { $0.startMs < $1.startMs }
        var items: [Annotation] = []
        for gap in sortedGaps where gap.durationMs >= minGapMs {
            items.append(
                Annotation(
                    kind: .gap(durationMs: gap.durationMs),
                    audioMs: audioOffsetMs(forWallMs: gap.startMs, gaps: sortedGaps)))
        }
        for mark in marks {
            items.append(
                Annotation(kind: .mark(mark.source), audioMs: audioOffsetMs(forWallMs: mark.atMs, gaps: sortedGaps)))
        }
        // 同一位置：中断在前（它发生在标记之前的那段静默里）
        return items.enumerated().sorted { a, b in
            if a.element.audioMs != b.element.audioMs { return a.element.audioMs < b.element.audioMs }
            let ag = rank(a.element.kind)
            let bg = rank(b.element.kind)
            return ag != bg ? ag < bg : a.offset < b.offset
        }.map(\.element)
    }

    private static func rank(_ kind: Annotation.Kind) -> Int {
        switch kind {
        case .gap: return 0
        case .mark: return 1
        }
    }

    /// 「此处中断 N 秒」的秒数（四舍五入，至少 1）。
    public static func gapSeconds(_ durationMs: Int) -> Int {
        max(1, Int((Double(durationMs) / 1000).rounded()))
    }
}
