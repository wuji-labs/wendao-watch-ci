// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import AVFoundation
import Foundation

/// AAC 单声道 16 kHz 分段录音器。只负责把声音写进给定文件；切段、清单与上传由上层负责。
@MainActor
final class AudioSegmentRecorder {
    /// 录满 `maxDuration` 后由系统停止（切段的主触发，后台也可靠）。
    var onReachedMaxDuration: (() -> Void)?
    /// 编码出错导致录音中断。
    var onEncodeError: ((String) -> Void)?

    private var recorder: AVAudioRecorder?
    private var delegateProxy: RecorderDelegateProxy?
    private(set) var segmentStartedAt: Date?

    static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16_000.0,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
    ]

    var isRecording: Bool { recorder?.isRecording ?? false }

    func start(url: URL, maxDuration: TimeInterval) throws {
        stopWithoutCallback()
        let r = try AVAudioRecorder(url: url, settings: Self.settings)
        let recorderId = ObjectIdentifier(r)
        let proxy = RecorderDelegateProxy { [weak self] event in
            guard let self, let current = self.recorder, ObjectIdentifier(current) == recorderId else { return }
            switch event {
            case .finished:
                self.recorder = nil
                self.delegateProxy = nil
                self.onReachedMaxDuration?()
            case .encodeError(let message):
                self.onEncodeError?(message)
            }
        }
        r.delegate = proxy
        r.isMeteringEnabled = true
        guard r.prepareToRecord(), r.record(forDuration: maxDuration) else {
            throw RecorderError.cannotStart
        }
        recorder = r
        delegateProxy = proxy
        segmentStartedAt = Date()
    }

    /// 主动停止当前段，返回已录时长（秒）。
    @discardableResult
    func stop() -> TimeInterval {
        guard let r = recorder else { return 0 }
        let elapsed = r.currentTime
        stopWithoutCallback()
        return elapsed
    }

    private func stopWithoutCallback() {
        guard let r = recorder else { return }
        recorder = nil
        delegateProxy = nil
        r.delegate = nil
        r.stop()
        segmentStartedAt = nil
    }

    /// 0…1 的电平，供界面显示。
    func normalizedLevel() -> Float {
        guard let r = recorder, r.isRecording else { return 0 }
        r.updateMeters()
        let db = r.averagePower(forChannel: 0)
        let floor: Float = -50
        guard db > floor else { return 0 }
        return min(1, (db - floor) / -floor)
    }

    enum RecorderError: LocalizedError {
        case cannotStart

        var errorDescription: String? { "录音器无法启动" }
    }
}

/// `AVAudioRecorderDelegate` 的回调线程不确定，统一转回主线程。
private final class RecorderDelegateProxy: NSObject, AVAudioRecorderDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case finished(success: Bool)
        case encodeError(String)
    }

    private let handler: @MainActor (Event) -> Void

    init(handler: @escaping @MainActor (Event) -> Void) {
        self.handler = handler
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let handler = self.handler
        Task { @MainActor in handler(.finished(success: flag)) }
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        let message = error?.localizedDescription ?? "编码错误"
        let handler = self.handler
        Task { @MainActor in handler(.encodeError(message)) }
    }
}

/// 用 AVFoundation 读出分段真实时长（毫秒）；文件不完整时返回 nil。
enum AudioDuration {
    static func probe(_ url: URL) async -> Int? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.isNumeric else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { return nil }
        return Int((seconds * 1000).rounded())
    }
}
