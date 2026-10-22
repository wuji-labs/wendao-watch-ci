// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import Foundation

/// 无缝切段的切点计算：把连续到来的 PCM 缓冲按固定帧数切成段，切点精确落在帧上，一帧不丢、不重。
///
/// 纯逻辑，不依赖 AVFoundation。换段是「惰性」的：一段恰好写满时不立即开新段，
/// 等下一块音频真正到来才换，这样停止录音时永远不会多出一个空段。
public struct GaplessSegmentCutter: Sendable, Equatable {
    /// 一次写入：先（按需）封口当前段并开新段，再把输入缓冲 `[offset, offset+count)` 写进当前段。
    public struct Chunk: Sendable, Equatable {
        public var startsNewSegment: Bool
        public var offset: Int
        public var count: Int

        public init(startsNewSegment: Bool, offset: Int, count: Int) {
            self.startsNewSegment = startsNewSegment
            self.offset = offset
            self.count = count
        }
    }

    public let framesPerSegment: Int
    /// 当前段已写帧数。
    public private(set) var framesInCurrentSegment = 0
    /// 自开始以来写入的总帧数。
    public private(set) var totalFrames: Int64 = 0

    public init(framesPerSegment: Int) {
        self.framesPerSegment = max(1, framesPerSegment)
    }

    /// 计算一块 `frameCount` 帧的输入应如何写入。
    public mutating func split(frameCount: Int) -> [Chunk] {
        guard frameCount > 0 else { return [] }
        var chunks: [Chunk] = []
        var offset = 0
        while offset < frameCount {
            var rotate = false
            if framesInCurrentSegment >= framesPerSegment {
                rotate = true
                framesInCurrentSegment = 0
            }
            let n = min(frameCount - offset, framesPerSegment - framesInCurrentSegment)
            chunks.append(Chunk(startsNewSegment: rotate, offset: offset, count: n))
            framesInCurrentSegment += n
            totalFrames += Int64(n)
            offset += n
        }
        return chunks
    }

    /// 外部原因（打断后续录）另起一段时调用：当前段计数归零。
    public mutating func startFreshSegment() {
        framesInCurrentSegment = 0
    }
}

/// 段文件的写入端。App 里由 AVAudioFile 实现；单测里用内存实现。
public protocol PCMSegmentSink: AnyObject {
    associatedtype Buffer

    /// 打开第 `seq` 段（创建文件）。
    func openSegment(seq: Int) throws
    /// 把 `buffer` 中 `[offset, offset+count)` 这些帧追加到当前段。
    func write(_ buffer: Buffer, offset: Int, count: Int) throws
    /// 封口第 `seq` 段（关闭文件、写尾）。`frames` 是该段写入的总帧数。
    func closeSegment(seq: Int, frames: Int) throws
}

/// 一个已封口的段。
public struct ClosedSegment: Sendable, Equatable {
    public var seq: Int
    public var frames: Int
    public var sampleRate: Double

    public init(seq: Int, frames: Int, sampleRate: Double) {
        self.seq = seq
        self.frames = frames
        self.sampleRate = sampleRate
    }

    /// 由帧数精确算出的时长（毫秒）。
    public var durationMs: Int {
        guard sampleRate > 0 else { return 0 }
        return Int((Double(frames) * 1000 / sampleRate).rounded())
    }
}

/// 把连续 PCM 流写成首尾相接的段文件：满 `framesPerSegment` 帧就在同一次 `append` 里封口旧段、打开新段继续写。
///
/// 不是线程安全的：调用方（音频 tap 回调）须串行调用。
public final class SegmentedPCMWriter<Sink: PCMSegmentSink> {
    public let sink: Sink
    public let sampleRate: Double
    private var cutter: GaplessSegmentCutter
    public private(set) var currentSeq: Int?

    /// 写满换段时回调（旧段已封口、新段已打开）。
    public var onRotate: ((_ closed: ClosedSegment, _ openedSeq: Int) -> Void)?

    public init(sink: Sink, sampleRate: Double, framesPerSegment: Int) {
        self.sink = sink
        self.sampleRate = sampleRate
        self.cutter = GaplessSegmentCutter(framesPerSegment: framesPerSegment)
    }

    public var framesInCurrentSegment: Int { cutter.framesInCurrentSegment }
    public var totalFrames: Int64 { cutter.totalFrames }

    /// 打开第一段。
    public func begin(seq: Int) throws {
        precondition(currentSeq == nil, "begin 只能调用一次")
        try sink.openSegment(seq: seq)
        currentSeq = seq
        cutter.startFreshSegment()
    }

    /// 追加 `frameCount` 帧。到达段长时在本次调用内换段。
    public func append(_ buffer: Sink.Buffer, frameCount: Int) throws {
        guard var seq = currentSeq else { return }
        for chunk in cutter.split(frameCount: frameCount) {
            if chunk.startsNewSegment {
                let closed = ClosedSegment(seq: seq, frames: cutter.framesPerSegment, sampleRate: sampleRate)
                try sink.closeSegment(seq: seq, frames: closed.frames)
                seq += 1
                currentSeq = seq
                try sink.openSegment(seq: seq)
                onRotate?(closed, seq)
            }
            try sink.write(buffer, offset: chunk.offset, count: chunk.count)
        }
    }

    /// 封口当前段并结束。返回最后一段（可能 0 帧：开始后还没有任何音频到来）。
    @discardableResult
    public func finish() throws -> ClosedSegment? {
        guard let seq = currentSeq else { return nil }
        currentSeq = nil
        let frames = cutter.framesInCurrentSegment
        try sink.closeSegment(seq: seq, frames: frames)
        return ClosedSegment(seq: seq, frames: frames, sampleRate: sampleRate)
    }
}
