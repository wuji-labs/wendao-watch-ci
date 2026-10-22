// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import Foundation
import WendaoKit

/// 两端共用的本地环境：数据目录、服务端地址、令牌存储、切段策略。
enum WendaoEnvironment {
    static let baseURLKey = "wendao.baseURL"

    /// `Application Support/Wendao`：系统不会在存储紧张时自动清理此目录。
    static var dataRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Wendao", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var uploadQueueStateURL: URL {
        dataRoot.appendingPathComponent("upload-queue.json")
    }

    static var scratchDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("wendao-upload", isDirectory: true)
    }

    static var store: ManifestStore { ManifestStore(root: dataRoot) }

    static var tokenStore: KeychainTokenStore { KeychainTokenStore() }

    static func makePolicy() -> SegmentRecorderPolicy {
        #if os(watchOS)
            SegmentRecorderPolicy(store: store, localSource: .watch)
        #else
            SegmentRecorderPolicy(store: store, localSource: .phone)
        #endif
    }

    static var baseURL: URL {
        get {
            UserDefaults.standard.string(forKey: baseURLKey).flatMap(WendaoServer.normalizedBaseURL)
                ?? WendaoServer.production
        }
        set {
            if newValue == WendaoServer.production {
                UserDefaults.standard.removeObject(forKey: baseURLKey)
            } else {
                UserDefaults.standard.set(newValue.absoluteString, forKey: baseURLKey)
            }
        }
    }

    /// 清理上次进程留下的 multipart 临时请求体（后台上传完成前进程被杀时会残留）。
    static func cleanScratch(olderThan age: TimeInterval = 24 * 3600) {
        let dir = scratchDirectory
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for name in names {
            let url = dir.appendingPathComponent(name)
            let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            if let modified, modified < cutoff { try? fm.removeItem(at: url) }
        }
    }
}
