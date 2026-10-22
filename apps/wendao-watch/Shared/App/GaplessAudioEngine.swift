// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import AVFoundation
import Foundation
import WendaoKit

/// 无缝录音引擎：`AVAudioEngine` 输入节点装 tap → 转成 16 kHz 单声道 → 连续写入当前段的 AAC 文件。
///
/// 满 5 分钟时在同一个 tap 回调里封口旧文件、打开新文件接着写，引擎不停，段与段之间一帧不丢。
/// 切点由 WendaoKit 的 `SegmentedPCMWriter` 按帧精确计算（有单测覆盖样本守恒）。
///
/// 线程：tap 回调在音频线程串行到来；控制方法（开始、停止）在主线程调用。内部状态一律在 `lock` 内读写，
/// 但停止引擎、拆 tap 一定在锁外进行——`AVAudioEngine.stop()` 会等正在执行的 tap 回调返回，持锁去停会互相等死。
final class GaplessAudioEngine: @unchecked Sendable {
    static let sampleRate: Double = 16_000

    /// 段文件编码：AAC、16 kHz、单声道。
    static var fileSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
    }

    /// 需要录音控制器处理的事。回调线程不定，由控制器自己转回主线程。
    enum Event: Sendable {
        /// 有段写满封口，待控制器封存（`takeClosedSegments()`）。
        case rotated
        /// 音频硬件重配置（如蓝牙耳机连上/断开）时引擎重启造成的瞬断，段文件不变。
        case glitch(from: Date, to: Date)
        /// 写文件或重配置后恢复失败，当前段已封口，引擎已失效。
        case failed(String)
    }

    enum EngineError: LocalizedError {
        case noInput
        case converterUnavailable
        case noOpenSegment
        case bufferAllocation
        case conversion(String)

        var errorDescription: String? {
            switch self {
            case .noInput: return "没有可用的麦克风输入"
            case .converterUnavailable: return "无法建立音频格式转换"
            case .noOpenSegment: return "没有打开的录音分段"
            case .bufferAllocation: return "音频缓冲分配失败"
            case .conversion(let m): return "音频格式转换失败：\(m)"
            }
        }
    }

    private let lock = NSLock()
    private let outputFormat: AVAudioFormat
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var writer: SegmentedPCMWriter<AudioFileSegmentSink>?
    private var closedPending: [ClosedSegment] = []
    private var meter: Float = 0
    private var configObserver: (any NSObjectProtocol)?
    private var eventHandler: (@Sendable (Event) -> Void)?

    init() {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false)
        else { preconditionFailure("16 kHz 单声道 Float32 是标准格式") }
        outputFormat = format
    }

    func setEventHandler(_ handler: @escaping @Sendable (Event) -> Void) {
        lock.withLock { eventHandler = handler }
    }

    /// 0…1 的电平，供界面显示。
    var normalizedLevel: Float { lock.withLock { meter } }

    var isRunning: Bool { lock.withLock { writer != nil } }

    // MARK: 开始与停止

    /// 从第 `firstSeq` 段开始录。`urlForSeq` 给出每段文件的位置（调用方须已在清单里登记第一段）。
    func start(firstSeq: Int, framesPerSegment: Int, urlForSeq: @escaping @Sendable (Int) -> URL) throws {
        _ = stop()
        try lock.withLock {
            let sink = AudioFileSegmentSink(urlForSeq: urlForSeq)
            let w = SegmentedPCMWriter(sink: sink, sampleRate: Self.sampleRate, framesPerSegment: framesPerSegment)
            // 在 tap 回调里（已持锁）触发：只记账并通知，封存交给主线程
            w.onRotate = { [unowned self] closed, _ in
                self.closedPending.append(closed)
                self.eventHandler?(.rotated)
            }
            try w.begin(seq: firstSeq)
            writer = w
            do {
                try startEngineLocked()
            } catch {
                if let last = try? w.finish() { closedPending.append(last) }
                writer = nil
                throw error
            }
        }
    }

    /// 停止并封口当前段。返回所有已封口但控制器尚未取走的段（含刚封口的最后一段，可能 0 帧）。
    @discardableResult
    func stop() -> [ClosedSegment] {
        let old: AVAudioEngine? = lock.withLock { detachEngineLocked() }
        old?.inputNode.removeTap(onBus: 0)
        old?.stop()
        return lock.withLock {
            if let w = writer {
                if let last = try? w.finish() { closedPending.append(last) }
                writer = nil
            }
            converter = nil
            meter = 0
            let all = closedPending
            closedPending = []
            return all
        }
    }

    /// 取走已封口、待封存的段。
    func takeClosedSegments() -> [ClosedSegment] {
        lock.withLock {
            let all = closedPending
            closedPending = []
            return all
        }
    }

    // MARK: 引擎

    /// 持锁调用。只建引擎、装 tap、启动；不会等待任何 tap 回调。
    private func startEngineLocked() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw EngineError.noInput }
        guard let conv = AVAudioConverter(from: inFormat, to: outputFormat) else {
            throw EngineError.converterUnavailable
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        self.converter = conv
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    /// 持锁调用：把引擎从状态里摘下（真正的停止在锁外做）。
    private func detachEngineLocked() -> AVAudioEngine? {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        let e = engine
        engine = nil
        return e
    }

    /// 输入设备或采样率变了，系统已停掉引擎：换新引擎、新转换器，继续写同一段文件。
    private func handleConfigurationChange() {
        let from = Date()
        let old: AVAudioEngine? = lock.withLock { writer == nil ? nil : detachEngineLocked() }
        guard let old else { return }
        old.inputNode.removeTap(onBus: 0)
        old.stop()
        let outcome: Event? = lock.withLock {
            guard writer != nil, engine == nil else { return nil }
            do {
                try startEngineLocked()
                return .glitch(from: from, to: Date())
            } catch {
                if let w = writer, let last = try? w.finish() { closedPending.append(last) }
                writer = nil
                converter = nil
                return .failed("音频设备变化后无法继续录音：\(error.localizedDescription)")
            }
        }
        if let outcome { emit(outcome) }
    }

    private func emit(_ event: Event) {
        let handler = lock.withLock { eventHandler }
        handler?(event)
    }

    // MARK: tap 回调

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        let failure: String? = lock.withLock {
            guard let writer, let converter else { return nil }
            do {
                let out = try convert(buffer, with: converter)
                let frames = Int(out.frameLength)
                guard frames > 0 else { return nil }
                meter = Self.level(of: out)
                try writer.append(out, frameCount: frames)
                return nil
            } catch {
                // 写不下去了：封口已写部分，停止接收；拆引擎由控制器在主线程做
                if let last = try? writer.finish() { closedPending.append(last) }
                self.writer = nil
                self.converter = nil
                return error.localizedDescription
            }
        }
        if let failure { emit(.failed(failure)) }
    }

    /// 转成 16 kHz 单声道。转换器跨回调保留滤波状态，所以缓冲之间的重采样也是连续的。
    private func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) throws -> AVAudioPCMBuffer {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw EngineError.bufferAllocation
        }
        let feed = TapFeed(buffer)
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if feed.consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            feed.consumed = true
            inputStatus.pointee = .haveData
            return feed.buffer
        }
        if status == .error {
            throw EngineError.conversion(error?.localizedDescription ?? "未知错误")
        }
        return out
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        let samples = data[0]
        var sum: Float = 0
        for i in 0..<n { sum += samples[i] * samples[i] }
        let rms = (sum / Float(n)).squareRoot()
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        let floor: Float = -50
        guard db > floor else { return 0 }
        return min(1, (db - floor) / -floor)
    }
}

/// 一次转换的输入：把 tap 给的缓冲交给转换器恰好一次。
private final class TapFeed: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var consumed = false

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

/// 段文件写入端：每段一个 `AVAudioFile`（AAC），释放即写尾封口。
final class AudioFileSegmentSink: PCMSegmentSink {
    typealias Buffer = AVAudioPCMBuffer

    private let urlForSeq: @Sendable (Int) -> URL
    private var file: AVAudioFile?

    init(urlForSeq: @escaping @Sendable (Int) -> URL) {
        self.urlForSeq = urlForSeq
    }

    func openSegment(seq: Int) throws {
        file = nil
        file = try AVAudioFile(
            forWriting: urlForSeq(seq), settings: GaplessAudioEngine.fileSettings, commonFormat: .pcmFormatFloat32,
            interleaved: false)
    }

    func write(_ buffer: AVAudioPCMBuffer, offset: Int, count: Int) throws {
        guard let file else { throw GaplessAudioEngine.EngineError.noOpenSegment }
        if offset == 0, count == Int(buffer.frameLength) {
            try file.write(from: buffer)
            return
        }
        guard let slice = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(count)),
            let src = buffer.floatChannelData, let dst = slice.floatChannelData
        else { throw GaplessAudioEngine.EngineError.bufferAllocation }
        for ch in 0..<Int(buffer.format.channelCount) {
            dst[ch].update(from: src[ch].advanced(by: offset), count: count)
        }
        slice.frameLength = AVAudioFrameCount(count)
        try file.write(from: slice)
    }

    func closeSegment(seq: Int, frames: Int) throws {
        // AVAudioFile 在释放时写完尾部（moov），文件随即可被读取与计算摘要
        file = nil
    }
}

/// 用 AVFoundation 读出分段真实时长（毫秒）；文件不完整时返回 nil。崩溃恢复时使用。
enum AudioDuration {
    static func probe(_ url: URL) async -> Int? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.isNumeric else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { return nil }
        return Int((seconds * 1000).rounded())
    }
}
