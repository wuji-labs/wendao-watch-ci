// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import Foundation

public enum WendaoAppGroup {
    public static let identifier = "group.com.wujilabs.wendao"

    /// App Group 的共享偏好；未配置 App Group（如未签名的模拟器构建）时退回标准偏好。
    public static func defaults() -> UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }
}

/// 录音指令（来自 App Intents：Action Button、控制中心、Smart Stack 小组件、快捷指令）。
public enum RecordingCommand: String, Codable, Sendable {
    case start
    case stop
    case toggle
}

/// 把指令交给正在运行的录音控制器；控制器尚未注册（App 刚被意图拉起）时先暂存，注册时补发。
@MainActor
public final class RecordingCommandCenter {
    public static let shared = RecordingCommandCenter()

    public typealias Handler = @MainActor (RecordingCommand) async -> Void

    private static let pendingKey = "wendao.pendingRecordingCommand"
    private static let pendingAtKey = "wendao.pendingRecordingCommandAt"
    /// 暂存的指令只在这段时间内有效，避免很久以前的点击在下次打开 App 时突然开录。
    public static let pendingTTL: TimeInterval = 60

    private var handler: Handler?
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = WendaoAppGroup.defaults()) {
        self.defaults = defaults
    }

    public var hasHandler: Bool { handler != nil }

    public func register(_ handler: @escaping Handler, now: Date = Date()) async {
        self.handler = handler
        if let pending = takePending(now: now) {
            await handler(pending)
        }
    }

    public func unregister() {
        handler = nil
    }

    public func submit(_ command: RecordingCommand, now: Date = Date()) async {
        if let handler {
            await handler(command)
        } else {
            defaults.set(command.rawValue, forKey: Self.pendingKey)
            defaults.set(now.timeIntervalSince1970, forKey: Self.pendingAtKey)
        }
    }

    func takePending(now: Date) -> RecordingCommand? {
        defer {
            defaults.removeObject(forKey: Self.pendingKey)
            defaults.removeObject(forKey: Self.pendingAtKey)
        }
        guard let raw = defaults.string(forKey: Self.pendingKey),
            let command = RecordingCommand(rawValue: raw)
        else { return nil }
        let at = defaults.double(forKey: Self.pendingAtKey)
        guard now.timeIntervalSince1970 - at <= Self.pendingTTL else { return nil }
        return command
    }
}

/// 录音状态快照，写入 App Group 供小组件显示。
public struct RecordingStatusSnapshot: Codable, Sendable, Equatable {
    public static let key = "wendao.recordingStatus"

    public var isRecording: Bool
    public var startedAt: Date?
    public var pendingSegments: Int
    public var updatedAt: Date

    public init(isRecording: Bool, startedAt: Date?, pendingSegments: Int, updatedAt: Date) {
        self.isRecording = isRecording
        self.startedAt = startedAt
        self.pendingSegments = pendingSegments
        self.updatedAt = updatedAt
    }

    public static let idle = RecordingStatusSnapshot(
        isRecording: false, startedAt: nil, pendingSegments: 0, updatedAt: Date(timeIntervalSince1970: 0))

    public static func load(from defaults: UserDefaults = WendaoAppGroup.defaults()) -> RecordingStatusSnapshot {
        guard let data = defaults.data(forKey: key),
            let snap = try? WendaoJSON.decoder().decode(RecordingStatusSnapshot.self, from: data)
        else { return .idle }
        return snap
    }

    public func save(to defaults: UserDefaults = WendaoAppGroup.defaults()) {
        if let data = try? WendaoJSON.encoder().encode(self) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
