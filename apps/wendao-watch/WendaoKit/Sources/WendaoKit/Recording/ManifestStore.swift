// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import Foundation

public enum ManifestStoreError: Error, Sendable, Equatable {
    case notFound(String)
    case invalidSessionId(String)
}

/// 会话清单的读写。目录结构：
///
/// ```
/// <root>/sessions/<clientSessionId>/manifest.json
/// <root>/sessions/<clientSessionId>/seg-00000.m4a
/// ```
public struct ManifestStore: Sendable {
    public static let manifestFileName = "manifest.json"

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var sessionsDirectory: URL {
        root.appendingPathComponent("sessions", isDirectory: true)
    }

    public func sessionDirectory(_ clientSessionId: String) -> URL {
        sessionsDirectory.appendingPathComponent(clientSessionId, isDirectory: true)
    }

    public func manifestURL(_ clientSessionId: String) -> URL {
        sessionDirectory(clientSessionId).appendingPathComponent(Self.manifestFileName)
    }

    public func fileURL(for segment: SegmentEntry, in clientSessionId: String) -> URL {
        sessionDirectory(clientSessionId).appendingPathComponent(segment.path)
    }

    public func save(_ manifest: SessionManifest) throws {
        try Self.validate(manifest.clientSessionId)
        let data = try WendaoJSON.encoder().encode(manifest)
        try FileManager.writeAtomically(data, to: manifestURL(manifest.clientSessionId))
    }

    public func load(_ clientSessionId: String) throws -> SessionManifest {
        try Self.validate(clientSessionId)
        let url = manifestURL(clientSessionId)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ManifestStoreError.notFound(clientSessionId)
        }
        return try WendaoJSON.decoder().decode(SessionManifest.self, from: Data(contentsOf: url))
    }

    public func loadIfPresent(_ clientSessionId: String) -> SessionManifest? {
        try? load(clientSessionId)
    }

    /// 读改写同一份清单。录音器（主线程）与上传队列（后台）都会改清单，
    /// 一律经此在进程级锁内「重新读取 → 修改 → 写回」，谁也不会用旧副本覆盖对方的改动。
    @discardableResult
    public func update(
        _ clientSessionId: String, _ body: (inout SessionManifest) throws -> Void
    ) throws -> SessionManifest {
        try modify(clientSessionId, orCreate: nil, body)
    }

    /// 同 `update`，清单不存在时用 `orCreate` 新建。
    @discardableResult
    public func modify(
        _ clientSessionId: String, orCreate: (() -> SessionManifest)?,
        _ body: (inout SessionManifest) throws -> Void
    ) throws -> SessionManifest {
        try Self.validate(clientSessionId)
        return try Self.lock.withLock {
            var m: SessionManifest
            if let existing = loadIfPresent(clientSessionId) {
                m = existing
            } else if let orCreate {
                m = orCreate()
                try FileManager.default.createDirectory(
                    at: sessionDirectory(clientSessionId), withIntermediateDirectories: true)
            } else {
                throw ManifestStoreError.notFound(clientSessionId)
            }
            try body(&m)
            try save(m)
            return m
        }
    }

    private static let lock = NSLock()

    /// 所有会话 id（目录名），不保证每个都有可读清单。
    public func sessionIds() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: sessionsDirectory.path)) ?? []
        return names.filter { (try? Self.validate($0)) != nil }.sorted()
    }

    /// 所有可读清单，最近开始的在前。
    public func allManifests() -> [SessionManifest] {
        sessionIds().compactMap { loadIfPresent($0) }.sorted { $0.startedAt > $1.startedAt }
    }

    public func deleteSession(_ clientSessionId: String) throws {
        try Self.validate(clientSessionId)
        let dir = sessionDirectory(clientSessionId)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    /// 会话 id 只允许 UUID 字符，防止被元数据带出目录。
    static func validate(_ id: String) throws {
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
        guard !id.isEmpty, id.count <= 64, id.unicodeScalars.allSatisfy(allowed.contains) else {
            throw ManifestStoreError.invalidSessionId(id)
        }
    }
}
