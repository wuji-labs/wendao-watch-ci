// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import Foundation
import WatchConnectivity
import WendaoKit

/// iPhone 侧 WatchConnectivity：接收手表的段文件与「会话结束」，向手表下发凭据。
///
/// 代理回调在后台线程到达。`WCSessionFile` 的临时文件在回调返回后即被系统删除，所以必须在回调里同步移走，
/// 再把可发送的值交回主线程处理。
final class PhoneConnectivity: NSObject, WCSessionDelegate, @unchecked Sendable {
    struct Handlers: Sendable {
        var segment: @MainActor @Sendable (WatchSegmentMetadata, URL) -> Void
        var sessionFinished: @MainActor @Sendable (WatchSessionFinished) -> Void
        var activated: @MainActor @Sendable () -> Void
    }

    private let inbox: URL
    private let handlers: Handlers

    init(inbox: URL, handlers: Handlers) {
        self.inbox = inbox
        self.handlers = handlers
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// 下发（或撤销）设备令牌。applicationContext 只保留最新一份，手表上线即取到。
    func sendCredentials(_ credentials: WatchCredentials) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        try? session.updateApplicationContext(credentials.dictionary)
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        guard activationState == .activated else { return }
        let activated = handlers.activated
        Task { @MainActor in activated() }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // 用户换了手表：重新激活以连接新手表
        session.activate()
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let raw = file.metadata, let meta = WatchSegmentMetadata(dictionary: raw) else { return }
        let staged = inbox.appendingPathComponent(UUID().uuidString + "." + file.fileURL.pathExtension)
        do {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: file.fileURL, to: staged)
        } catch {
            return
        }
        let handler = handlers.segment
        Task { @MainActor in handler(meta, staged) }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let info = WatchSessionFinished(dictionary: userInfo) else { return }
        let handler = handlers.sessionFinished
        Task { @MainActor in handler(info) }
    }
}
