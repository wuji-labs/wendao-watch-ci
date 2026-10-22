// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import Foundation

// MARK: 设备绑定（packages/miaoji-contracts/src/saas.ts）

public struct SendDeviceBindCodeInput: Codable, Sendable, Equatable {
    public var phone: String
}

public struct SendCodeOutput: Codable, Sendable, Equatable {
    public var ok: Bool
    /// 仅开发环境回显，生产恒为空。
    public var devCode: String?
    public var retryAfterSec: Int
}

public struct BindDeviceWithCodeInput: Codable, Sendable, Equatable {
    public var phone: String
    public var code: String
    public var deviceName: String
}

public struct BindDeviceOutput: Codable, Sendable, Equatable {
    public var deviceToken: String
    public var userId: String
    public var deviceName: String
}

// MARK: 录音会话（W1 合同 `recording.*`）

public struct RecordingBeginInput: Codable, Sendable, Equatable {
    public var title: String?
    public var startedAt: Date
    public var language: String
    public var clientSessionId: String

    public init(title: String?, startedAt: Date, language: String, clientSessionId: String) {
        self.title = title
        self.startedAt = startedAt
        self.language = language
        self.clientSessionId = clientSessionId
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(language, forKey: .language)
        try c.encode(clientSessionId, forKey: .clientSessionId)
    }
}

public struct RecordingBeginOutput: Codable, Sendable, Equatable {
    public var sessionId: String
}

public struct RecordingSessionRef: Codable, Sendable, Equatable {
    public var sessionId: String
}

/// `recording.status` 的返回（`packages/miaoji-contracts/src/recording.ts` 的 `RecordingStatusOutput`）。
public struct RecordingStatusOutput: Decodable, Sendable, Equatable {
    /// `OPEN` 收分段 · `FINALIZING` 拼接中 · `DONE` 已登记妙记 · `FAILED` 拼接失败（可再次终结）
    public var status: String?
    /// 已收分段序号（升序）。
    public var receivedSeqs: [Int]
    /// 最近一次终结声明的分段总数。
    public var expectedSegments: Int?
    public var minuteId: String?
    public var token: String?
    public var errorMessage: String?

    public init(
        status: String?, receivedSeqs: [Int], expectedSegments: Int? = nil, minuteId: String? = nil,
        token: String? = nil, errorMessage: String? = nil
    ) {
        self.status = status
        self.receivedSeqs = receivedSeqs
        self.expectedSegments = expectedSegments
        self.minuteId = minuteId
        self.token = token
        self.errorMessage = errorMessage
    }

    private enum CodingKeys: String, CodingKey {
        case status, receivedSeqs, expectedSegments, minuteId, token, errorMessage
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        receivedSeqs = try c.decode([Int].self, forKey: .receivedSeqs).sorted()
        expectedSegments = try c.decodeIfPresent(Int.self, forKey: .expectedSegments)
        minuteId = try c.decodeIfPresent(String.self, forKey: .minuteId)
        token = try c.decodeIfPresent(String.self, forKey: .token)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
    }

    /// 服务端已生成妙记（例如另一端已经终结过）。
    public var finalizedMinute: RecordingFinalizeOutput? {
        guard status == "DONE", let minuteId, let token else { return nil }
        return RecordingFinalizeOutput(minuteId: minuteId, token: token)
    }
}

public struct RecordingFinalizeInput: Codable, Sendable, Equatable {
    public var sessionId: String
    public var expectedSegments: Int
}

public struct RecordingFinalizeOutput: Codable, Sendable, Equatable {
    public var minuteId: String
    public var token: String

    public init(minuteId: String, token: String) {
        self.minuteId = minuteId
        self.token = token
    }
}

/// `POST /upload/segment` 成功响应；`duplicate` 表示同哈希重传、服务端未重复写入。
public struct RecordingSegmentAck: Codable, Sendable, Equatable {
    public var sessionId: String
    public var seq: Int
    public var sha256: String
    public var sizeBytes: Int
    public var duplicate: Bool
}

/// 一次分段上传的描述（`POST /upload/segment`，multipart）。
public struct SegmentUpload: Sendable, Equatable {
    public var sessionId: String
    public var seq: Int
    public var sha256: String
    public var fileURL: URL
    public var fileName: String

    public init(sessionId: String, seq: Int, sha256: String, fileURL: URL, fileName: String) {
        self.sessionId = sessionId
        self.seq = seq
        self.sha256 = sha256
        self.fileURL = fileURL
        self.fileName = fileName
    }
}

// MARK: 妙记查询（packages/miaoji-api/src/trpc/routers/minute.ts）

public struct MinuteIdInput: Codable, Sendable, Equatable {
    public var id: String
}

public struct MinuteTokenInput: Codable, Sendable, Equatable {
    public var token: String
}

public enum MinuteProcessingStatus: String, Codable, Sendable {
    case uploading = "UPLOADING"
    case transcoding = "TRANSCODING"
    case transcribing = "TRANSCRIBING"
    case diarizing = "DIARIZING"
    case segmenting = "SEGMENTING"
    case summarizing = "SUMMARIZING"
    case ready = "READY"
    case failed = "FAILED"
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MinuteProcessingStatus(rawValue: raw) ?? .unknown
    }

    public var isTerminal: Bool { self == .ready || self == .failed }

    public var label: String {
        switch self {
        case .uploading: return "等待处理"
        case .transcoding: return "转码中"
        case .transcribing: return "转写中"
        case .diarizing: return "区分说话人"
        case .segmenting: return "整理段落"
        case .summarizing: return "生成纪要"
        case .ready: return "已完成"
        case .failed: return "失败"
        case .unknown: return "处理中"
        }
    }
}

public struct MinuteJob: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var stage: String
    public var status: String
    public var progress: Double
    public var errorMessage: String?
}

/// `minute.status` 的返回。
public struct MinuteStatus: Decodable, Sendable, Equatable {
    public var id: String
    public var status: MinuteProcessingStatus
    public var errorMessage: String?
    public var durationMs: Int
    public var title: String
    public var jobs: [MinuteJob]

    /// 0…1 的总体进度（各阶段均值）。
    public var overallProgress: Double {
        if status == .ready { return 1 }
        guard !jobs.isEmpty else { return 0 }
        return jobs.reduce(0) { $0 + min(max($1.progress, 0), 1) } / Double(jobs.count)
    }
}

/// `minute.getByToken` 的返回，只解码客户端用到的字段。
public struct MinuteDetail: Decodable, Sendable, Equatable {
    public struct Minute: Decodable, Sendable, Equatable {
        public var id: String
        public var token: String
        public var title: String
        public var status: MinuteProcessingStatus
        public var durationMs: Int
        public var errorMessage: String?
        public var createdAt: Date?
    }

    public struct Speaker: Decodable, Sendable, Equatable, Identifiable {
        public var id: String
        public var displayName: String
        public var orderIndex: Int
        public var colorHex: String?
        public var speakingRatio: Double?
    }

    public struct TranscriptSegment: Decodable, Sendable, Equatable, Identifiable {
        public var id: String
        public var speakerId: String?
        public var startMs: Int
        public var endMs: Int
        public var text: String
        public var orderIndex: Int
    }

    public struct KeyPoint: Decodable, Sendable, Equatable {
        public var text: String
        public var sourceSegmentId: String?
    }

    public struct Summary: Decodable, Sendable, Equatable {
        public var overview: String
        public var keyPoints: [KeyPoint]
        public var risks: [String]
        public var status: String
    }

    public struct Chapter: Decodable, Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        public var startMs: Int
        public var endMs: Int
        public var summary: String
        public var orderIndex: Int
    }

    public struct Todo: Decodable, Sendable, Equatable, Identifiable {
        public var id: String
        public var text: String
        public var owner: String?
        public var status: String
        public var orderIndex: Int
    }

    public var minute: Minute
    public var role: String?
    public var speakers: [Speaker]
    public var segments: [TranscriptSegment]
    public var summary: Summary?
    public var chapters: [Chapter]
    public var todos: [Todo]

    /// 相邻且同一说话人的句段合并成一段，便于阅读。
    public struct SpeakerTurn: Sendable, Equatable, Identifiable {
        public var id: String
        public var speaker: Speaker?
        public var startMs: Int
        public var endMs: Int
        public var text: String
    }

    public var speakerTurns: [SpeakerTurn] {
        let byId = Dictionary(speakers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var turns: [SpeakerTurn] = []
        for seg in segments.sorted(by: { $0.orderIndex < $1.orderIndex }) {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let last = turns.last, last.speaker?.id == seg.speakerId {
                turns[turns.count - 1].text += text
                turns[turns.count - 1].endMs = seg.endMs
            } else {
                turns.append(
                    SpeakerTurn(
                        id: seg.id, speaker: seg.speakerId.flatMap { byId[$0] }, startMs: seg.startMs,
                        endMs: seg.endMs, text: text))
            }
        }
        return turns
    }
}
