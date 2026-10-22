// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import Foundation

/// 手表与 iPhone 之间的消息。WatchConnectivity 只收属性列表类型，这里统一做字典编解码。
public enum WatchMessageKind: String, Sendable {
    case segment
    case sessionFinished
    case credentials
}

private enum Key {
    static let kind = "kind"
    static let clientSessionId = "clientSessionId"
    static let seq = "seq"
    static let sha256 = "sha256"
    static let durationMs = "durationMs"
    static let sessionStartedAt = "sessionStartedAt"
    static let finishedAt = "finishedAt"
    static let segmentCount = "segmentCount"
    static let title = "title"
    static let language = "language"
    static let deviceToken = "deviceToken"
    static let baseURL = "baseURL"
    static let issuedAt = "issuedAt"
}

/// `WCSession.transferFile` 随段文件附带的元数据。
public struct WatchSegmentMetadata: Sendable, Equatable {
    public var clientSessionId: String
    public var seq: Int
    public var sha256: String
    public var durationMs: Int?
    public var sessionStartedAt: Date
    public var title: String?
    public var language: String

    public init(
        clientSessionId: String, seq: Int, sha256: String, durationMs: Int?, sessionStartedAt: Date,
        title: String?, language: String
    ) {
        self.clientSessionId = clientSessionId
        self.seq = seq
        self.sha256 = sha256
        self.durationMs = durationMs
        self.sessionStartedAt = sessionStartedAt
        self.title = title
        self.language = language
    }

    public init?(manifest: SessionManifest, segment: SegmentEntry) {
        guard let sha = segment.sha256 else { return nil }
        self.init(
            clientSessionId: manifest.clientSessionId, seq: segment.seq, sha256: sha,
            durationMs: segment.durationMs, sessionStartedAt: manifest.startedAt, title: manifest.title,
            language: manifest.language)
    }

    public var dictionary: [String: Any] {
        var d: [String: Any] = [
            Key.kind: WatchMessageKind.segment.rawValue,
            Key.clientSessionId: clientSessionId,
            Key.seq: seq,
            Key.sha256: sha256,
            Key.sessionStartedAt: sessionStartedAt.timeIntervalSince1970,
            Key.language: language
        ]
        if let durationMs { d[Key.durationMs] = durationMs }
        if let title { d[Key.title] = title }
        return d
    }

    public init?(dictionary d: [String: Any]) {
        guard d[Key.kind] as? String == WatchMessageKind.segment.rawValue,
            let id = d[Key.clientSessionId] as? String,
            let seq = (d[Key.seq] as? NSNumber)?.intValue,
            let sha = d[Key.sha256] as? String,
            let started = (d[Key.sessionStartedAt] as? NSNumber)?.doubleValue
        else { return nil }
        self.init(
            clientSessionId: id, seq: seq, sha256: sha,
            durationMs: (d[Key.durationMs] as? NSNumber)?.intValue,
            sessionStartedAt: Date(timeIntervalSince1970: started),
            title: d[Key.title] as? String,
            language: d[Key.language] as? String ?? "zh")
    }
}

/// 手表结束一次录音后经 `transferUserInfo` 告知 iPhone。
public struct WatchSessionFinished: Sendable, Equatable {
    public var clientSessionId: String
    public var sessionStartedAt: Date
    public var finishedAt: Date
    public var segmentCount: Int
    public var title: String?
    public var language: String

    public init(
        clientSessionId: String, sessionStartedAt: Date, finishedAt: Date, segmentCount: Int,
        title: String?, language: String
    ) {
        self.clientSessionId = clientSessionId
        self.sessionStartedAt = sessionStartedAt
        self.finishedAt = finishedAt
        self.segmentCount = segmentCount
        self.title = title
        self.language = language
    }

    public init?(manifest: SessionManifest) {
        guard let finished = manifest.finishedAt else { return nil }
        self.init(
            clientSessionId: manifest.clientSessionId, sessionStartedAt: manifest.startedAt,
            finishedAt: finished, segmentCount: manifest.sealedSegments.count, title: manifest.title,
            language: manifest.language)
    }

    public var dictionary: [String: Any] {
        var d: [String: Any] = [
            Key.kind: WatchMessageKind.sessionFinished.rawValue,
            Key.clientSessionId: clientSessionId,
            Key.sessionStartedAt: sessionStartedAt.timeIntervalSince1970,
            Key.finishedAt: finishedAt.timeIntervalSince1970,
            Key.segmentCount: segmentCount,
            Key.language: language
        ]
        if let title { d[Key.title] = title }
        return d
    }

    public init?(dictionary d: [String: Any]) {
        guard d[Key.kind] as? String == WatchMessageKind.sessionFinished.rawValue,
            let id = d[Key.clientSessionId] as? String,
            let started = (d[Key.sessionStartedAt] as? NSNumber)?.doubleValue,
            let finished = (d[Key.finishedAt] as? NSNumber)?.doubleValue,
            let count = (d[Key.segmentCount] as? NSNumber)?.intValue
        else { return nil }
        self.init(
            clientSessionId: id, sessionStartedAt: Date(timeIntervalSince1970: started),
            finishedAt: Date(timeIntervalSince1970: finished), segmentCount: count,
            title: d[Key.title] as? String, language: d[Key.language] as? String ?? "zh")
    }
}

/// iPhone 经 `updateApplicationContext` 下发给手表的凭据。手表收到后写入自己的钥匙串，不落明文文件。
public struct WatchCredentials: Sendable, Equatable {
    /// nil 表示 iPhone 已解除绑定，手表应清除令牌。
    public var deviceToken: String?
    public var baseURL: URL
    public var issuedAt: Date

    public init(deviceToken: String?, baseURL: URL, issuedAt: Date) {
        self.deviceToken = deviceToken
        self.baseURL = baseURL
        self.issuedAt = issuedAt
    }

    public var dictionary: [String: Any] {
        var d: [String: Any] = [
            Key.kind: WatchMessageKind.credentials.rawValue,
            Key.baseURL: baseURL.absoluteString,
            Key.issuedAt: issuedAt.timeIntervalSince1970
        ]
        if let deviceToken { d[Key.deviceToken] = deviceToken }
        return d
    }

    public init?(dictionary d: [String: Any]) {
        guard d[Key.kind] as? String == WatchMessageKind.credentials.rawValue,
            let base = (d[Key.baseURL] as? String).flatMap(URL.init(string:)),
            let issued = (d[Key.issuedAt] as? NSNumber)?.doubleValue
        else { return nil }
        self.init(
            deviceToken: d[Key.deviceToken] as? String, baseURL: base,
            issuedAt: Date(timeIntervalSince1970: issued))
    }

    public static func kind(of dictionary: [String: Any]) -> WatchMessageKind? {
        (dictionary[Key.kind] as? String).flatMap(WatchMessageKind.init(rawValue:))
    }
}
