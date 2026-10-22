// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import Foundation

/// 录音会话在列表中的状态：录制中 / 上传中 / 转写中 / 已完成 / 失败。
public enum SessionDisplayState: Sendable, Equatable {
    case recording
    case uploading(uploaded: Int, total: Int, retryMessage: String?)
    case transcribing(progress: Double, stage: String)
    case completed
    case failed(String)

    public var label: String {
        switch self {
        case .recording: return "录制中"
        case .uploading: return "上传中"
        case .transcribing: return "转写中"
        case .completed: return "已完成"
        case .failed: return "失败"
        }
    }

    public var detail: String? {
        switch self {
        case .recording: return nil
        case .uploading(let uploaded, let total, let retry):
            if let retry { return "\(uploaded)/\(total) 段 · \(retry)" }
            return "\(uploaded)/\(total) 段"
        case .transcribing(let progress, let stage):
            return "\(stage) \(Int((progress * 100).rounded()))%"
        case .completed: return nil
        case .failed(let message): return message
        }
    }

    /// 由本地清单、上传任务与服务端妙记状态推导。
    public static func derive(
        manifest: SessionManifest, job: UploadJob?, minute: MinuteStatus?, isActiveRecording: Bool
    ) -> SessionDisplayState {
        if isActiveRecording { return .recording }
        if let job {
            switch job.phase {
            case .corrupted, .failed:
                return .failed(job.lastError ?? "上传失败")
            case .done:
                guard let minute else { return .transcribing(progress: 0, stage: "排队中") }
                switch minute.status {
                case .ready: return .completed
                case .failed: return .failed(minute.errorMessage ?? "转写失败")
                default:
                    return .transcribing(progress: minute.overallProgress, stage: minute.status.label)
                }
            case .uploading:
                break
            }
        }
        if !manifest.isFinished && manifest.source == .watch {
            // 从手表收来、手表仍在录
            return .recording
        }
        let total = max(manifest.sealedSegments.count, manifest.expectedSegmentCount ?? 0)
        let uploaded = manifest.sealedSegments.filter(\.uploaded).count
        return .uploading(uploaded: uploaded, total: total, retryMessage: job?.lastError)
    }
}

public enum DurationText {
    /// 「1:02:03」或「12:34」。
    public static func clock(ms: Int) -> String {
        let total = max(0, ms / 1000)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        func two(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
        return h > 0 ? "\(h):\(two(m)):\(two(s))" : "\(m):\(two(s))"
    }
}
