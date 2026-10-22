// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import Foundation
import Network
import WatchConnectivity
import WendaoKit

/// 手表侧 WatchConnectivity：把段文件交给 iPhone、接收 iPhone 下发的凭据。
final class WatchConnectivityClient: NSObject, WCSessionDelegate, @unchecked Sendable {
    struct Handlers: Sendable {
        var credentials: @MainActor @Sendable (WatchCredentials) -> Void
        /// 某段已成功交给 iPhone（clientSessionId, seq）。
        var segmentDelivered: @MainActor @Sendable (String, Int) -> Void
        var reachabilityChanged: @MainActor @Sendable (Bool) -> Void
    }

    private let handlers: Handlers

    init(handlers: Handlers) {
        self.handlers = handlers
        super.init()
    }

    func activate() {
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    var isPhoneReachable: Bool {
        WCSession.default.activationState == .activated && WCSession.default.isReachable
    }

    /// 排队发送一个段文件。WatchConnectivity 会在 iPhone 可达时自动投递，App 退出后也会继续。
    func send(segmentAt url: URL, metadata: WatchSegmentMetadata) {
        guard WCSession.default.activationState == .activated else { return }
        let pending = WCSession.default.outstandingFileTransfers.contains {
            $0.file.fileURL == url && $0.isTransferring
        }
        guard !pending else { return }
        WCSession.default.transferFile(url, metadata: metadata.dictionary)
    }

    func sendSessionFinished(_ info: WatchSessionFinished) {
        guard WCSession.default.activationState == .activated else { return }
        WCSession.default.transferUserInfo(info.dictionary)
    }

    /// 已排队、尚未送达的段文件（避免重复排队）。
    func outstandingFileURLs() -> Set<URL> {
        Set(WCSession.default.outstandingFileTransfers.map(\.file.fileURL))
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        guard activationState == .activated else { return }
        let context = session.receivedApplicationContext
        if !context.isEmpty, let creds = WatchCredentials(dictionary: context) {
            let handler = handlers.credentials
            Task { @MainActor in handler(creds) }
        }
        let reachable = session.isReachable
        let reach = handlers.reachabilityChanged
        Task { @MainActor in reach(reachable) }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let creds = WatchCredentials(dictionary: applicationContext) else { return }
        let handler = handlers.credentials
        Task { @MainActor in handler(creds) }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        let handler = handlers.reachabilityChanged
        Task { @MainActor in handler(reachable) }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: (any Error)?) {
        guard error == nil, let raw = fileTransfer.file.metadata,
            let meta = WatchSegmentMetadata(dictionary: raw)
        else { return }
        let handler = handlers.segmentDelivered
        let id = meta.clientSessionId
        let seq = meta.seq
        Task { @MainActor in handler(id, seq) }
    }
}

/// 手表自身的网络状态（Wi-Fi / 蜂窝）。
final class NetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.wujilabs.wendao.network")

    func start(_ handler: @escaping @MainActor @Sendable (Bool) -> Void) {
        monitor.pathUpdateHandler = { path in
            let ok = path.status == .satisfied
            Task { @MainActor in handler(ok) }
        }
        monitor.start(queue: queue)
    }
}
