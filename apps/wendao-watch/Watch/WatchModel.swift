// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import Foundation
import Observation
import WatchKit
import WendaoKit
import WidgetKit

/// 手表端状态：录音、经 iPhone 中转、iPhone 不在身边时直传。
@MainActor
@Observable
final class WatchModel {
    private(set) var isBound: Bool
    private(set) var phoneReachable = false
    private(set) var networkAvailable = false
    /// 尚未交给 iPhone 也未被服务端确认的分段数。
    private(set) var pendingSegments = 0

    @ObservationIgnored let recording: RecordingController
    @ObservationIgnored private let policy: SegmentRecorderPolicy
    @ObservationIgnored private var connectivity: WatchConnectivityClient?
    @ObservationIgnored private let network = NetworkMonitor()
    @ObservationIgnored private var api: WendaoAPI
    @ObservationIgnored private var queue: UploadQueue
    @ObservationIgnored private var directUploadTask: Task<Void, Never>?

    init() {
        let policy = WendaoEnvironment.makePolicy()
        self.policy = policy
        self.recording = RecordingController(policy: policy)
        self.isBound = (try? WendaoEnvironment.tokenStore.readToken()) != nil
        let api = Self.makeAPI(baseURL: WendaoEnvironment.baseURL)
        self.api = api
        self.queue = UploadQueue(store: policy.store, backend: api, stateURL: WendaoEnvironment.uploadQueueStateURL)

        recording.onSegmentSealed = { [weak self] manifest, segment in
            self?.deliver(manifest: manifest, segment: segment)
        }
        recording.onSessionFinished = { [weak self] manifest in
            self?.sessionFinished(manifest)
        }
        recording.onStatusChanged = { [weak self] _ in
            self?.refreshPending()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private static func makeAPI(baseURL: URL) -> WendaoAPI {
        WendaoAPI(
            baseURL: baseURL, scratchDirectory: WendaoEnvironment.scratchDirectory,
            tokenProvider: { try? WendaoEnvironment.tokenStore.readToken() })
    }

    func launch() async {
        WendaoEnvironment.cleanScratch()
        await RecordingCommandCenter.shared.register { [weak self] command in
            await self?.recording.handle(command)
        }
        let client = WatchConnectivityClient(
            handlers: .init(
                credentials: { [weak self] creds in self?.apply(creds) },
                segmentDelivered: { [weak self] id, seq in self?.markDelivered(id, seq: seq) },
                reachabilityChanged: { [weak self] reachable in
                    self?.phoneReachable = reachable
                    self?.resendUndelivered()
                    self?.maybeUploadDirectly()
                }))
        connectivity = client
        client.activate()
        network.start { [weak self] ok in
            self?.networkAvailable = ok
            self?.maybeUploadDirectly()
        }

        _ = await policy.recover(
            activeSessionId: recording.activeSessionId, probe: { await AudioDuration.probe($0) }, now: Date())
        refreshPending()
        resendUndelivered()
    }

    // MARK: 凭据

    private func apply(_ creds: WatchCredentials) {
        if let token = creds.deviceToken {
            try? WendaoEnvironment.tokenStore.writeToken(token)
            isBound = true
        } else {
            try? WendaoEnvironment.tokenStore.deleteToken()
            isBound = false
        }
        if creds.baseURL != WendaoEnvironment.baseURL {
            WendaoEnvironment.baseURL = creds.baseURL
            api = Self.makeAPI(baseURL: creds.baseURL)
            queue = UploadQueue(store: policy.store, backend: api, stateURL: WendaoEnvironment.uploadQueueStateURL)
        }
        let queue = self.queue
        Task {
            await queue.resumeAfterAuthentication()
            self.maybeUploadDirectly()
        }
    }

    // MARK: 传输

    private func deliver(manifest: SessionManifest, segment: SegmentEntry) {
        guard let meta = WatchSegmentMetadata(manifest: manifest, segment: segment) else { return }
        connectivity?.send(segmentAt: policy.store.fileURL(for: segment, in: manifest.clientSessionId), metadata: meta)
        refreshPending()
        maybeUploadDirectly()
    }

    private func sessionFinished(_ manifest: SessionManifest) {
        if let info = WatchSessionFinished(manifest: manifest) {
            connectivity?.sendSessionFinished(info)
        }
        refreshPending()
        maybeUploadDirectly()
    }

    private func markDelivered(_ clientSessionId: String, seq: Int) {
        _ = try? policy.store.update(clientSessionId) { m in
            m.updateSegment(seq: seq) { $0.transferred = true }
        }
        pruneDeliveredSessions()
        refreshPending()
    }

    /// 重新排队尚未交给 iPhone 的分段（例如进程曾被杀、或首次激活前录的段）。
    private func resendUndelivered() {
        guard let connectivity else { return }
        let outstanding = connectivity.outstandingFileURLs()
        for m in policy.store.allManifests() {
            for seg in m.sealedSegments where !seg.transferred && !seg.uploaded {
                let url = policy.store.fileURL(for: seg, in: m.clientSessionId)
                guard !outstanding.contains(url), let meta = WatchSegmentMetadata(manifest: m, segment: seg) else {
                    continue
                }
                connectivity.send(segmentAt: url, metadata: meta)
            }
            if m.isFinished, m.clientSessionId != recording.activeSessionId, let info = WatchSessionFinished(manifest: m),
                m.sealedSegments.contains(where: { !$0.transferred })
            {
                connectivity.sendSessionFinished(info)
            }
        }
    }

    /// iPhone 不可达且手表自己有网时，手表直接走上传队列传到闻道。
    ///
    /// 与经 iPhone 中转同时发生也安全：两端用同一 clientSessionId 与令牌，服务端按序号与摘要幂等。
    private func maybeUploadDirectly() {
        guard isBound, networkAvailable, !phoneReachable, directUploadTask == nil else { return }
        let queue = self.queue
        let ids = policy.store.allManifests()
            .filter { $0.sealedSegments.contains { !$0.uploaded && !$0.transferred } }
            .map(\.clientSessionId)
        guard !ids.isEmpty else { return }
        directUploadTask = Task { [weak self] in
            for id in ids { await queue.enqueue(id) }
            await queue.drain(sleep: { seconds in try await Task.sleep(for: .seconds(min(seconds, 120))) })
            self?.directUploadTask = nil
            self?.pruneDeliveredSessions()
            self?.refreshPending()
        }
    }

    /// 已收尾、且每段都已交给 iPhone 或被服务端确认的会话，删除本地文件，节省手表存储。
    private func pruneDeliveredSessions() {
        for m in policy.store.allManifests() where m.isFinished && m.clientSessionId != recording.activeSessionId {
            let allSafe = m.segments.allSatisfy { $0.transferred || $0.uploaded || $0.corrupted }
            guard allSafe else { continue }
            try? policy.store.deleteSession(m.clientSessionId)
            let queue = self.queue
            let id = m.clientSessionId
            Task { await queue.remove(id) }
        }
    }

    private func refreshPending() {
        pendingSegments = policy.store.allManifests().reduce(0) { total, m in
            total + m.sealedSegments.filter { !$0.transferred && !$0.uploaded }.count
        }
        var snap = RecordingStatusSnapshot.load()
        snap.pendingSegments = pendingSegments
        snap.save()
    }
}
