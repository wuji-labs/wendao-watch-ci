// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import Foundation
import Observation
import UIKit
import WendaoKit

/// iPhone 端的应用状态：绑定、会话列表、上传队列、手表中转、妙记状态。
@MainActor
@Observable
final class AppModel {
    static let consentKey = "wendao.consentAccepted.v1"

    var consentAccepted: Bool {
        didSet { UserDefaults.standard.set(consentAccepted, forKey: Self.consentKey) }
    }
    private(set) var isBound: Bool
    private(set) var needsRebind = false
    private(set) var sessions: [SessionManifest] = []
    private(set) var jobs: [String: UploadJob] = [:]
    private(set) var minuteStatuses: [String: MinuteStatus] = [:]
    private(set) var baseURL: URL
    var lastError: String?

    @ObservationIgnored let recording: RecordingController
    @ObservationIgnored let backgroundTransport: BackgroundUploadTransport
    @ObservationIgnored private(set) var api: WendaoAPI
    @ObservationIgnored private var queue: UploadQueue
    @ObservationIgnored private var observerId: UUID?
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var connectivity: PhoneConnectivity?
    @ObservationIgnored private let policy: SegmentRecorderPolicy

    init() {
        let policy = WendaoEnvironment.makePolicy()
        self.policy = policy
        self.consentAccepted = UserDefaults.standard.bool(forKey: Self.consentKey)
        self.isBound = ((try? WendaoEnvironment.tokenStore.readToken()) ?? nil) != nil
        self.baseURL = WendaoEnvironment.baseURL
        self.recording = RecordingController(policy: policy)
        let background = BackgroundUploadTransport()
        self.backgroundTransport = background
        let api = Self.makeAPI(baseURL: WendaoEnvironment.baseURL, upload: background)
        self.api = api
        self.queue = Self.makeQueue(policy: policy, api: api)

        recording.onSegmentSealed = { [weak self] manifest, _ in self?.enqueue(manifest.clientSessionId) }
        recording.onSessionFinished = { [weak self] manifest in self?.enqueue(manifest.clientSessionId) }
        recording.onStatusChanged = { [weak self] _ in self?.reloadSessions() }
    }

    private static func makeAPI(baseURL: URL, upload: BackgroundUploadTransport) -> WendaoAPI {
        WendaoAPI(
            baseURL: baseURL, transport: URLSessionTransport(), uploadTransport: upload,
            scratchDirectory: WendaoEnvironment.scratchDirectory,
            tokenProvider: { try? WendaoEnvironment.tokenStore.readToken() })
    }

    private static func makeQueue(policy: SegmentRecorderPolicy, api: WendaoAPI) -> UploadQueue {
        UploadQueue(store: policy.store, backend: api, stateURL: WendaoEnvironment.uploadQueueStateURL)
    }

    // MARK: 启动

    func launch() async {
        WendaoEnvironment.cleanScratch()
        await RecordingCommandCenter.shared.register { [weak self] command in
            await self?.recording.handle(command)
        }
        await attachQueueObserver()

        let connectivity = PhoneConnectivity(
            inbox: WendaoEnvironment.dataRoot.appendingPathComponent("inbox", isDirectory: true),
            handlers: .init(
                segment: { [weak self] meta, url in self?.receiveWatchSegment(meta, stagedFile: url) },
                sessionFinished: { [weak self] info in self?.receiveWatchSessionFinished(info) },
                activated: { [weak self] in self?.pushCredentialsToWatch() }))
        self.connectivity = connectivity
        connectivity.activate()

        _ = await policy.recover(
            activeSessionId: recording.activeSessionId, probe: { await AudioDuration.probe($0) }, now: Date())
        reloadSessions()
        for m in sessions where jobs[m.clientSessionId]?.phase != .done {
            await queue.enqueue(m.clientSessionId)
        }
        kickUploads()
        startPollingMinutes()
    }

    func becameActive() {
        recording.resumeIfInterrupted()
        reloadSessions()
        Task { await queue.retryNow() }
        kickUploads()
        startPollingMinutes()
    }

    private func attachQueueObserver() async {
        if let observerId { await queue.removeObserver(observerId) }
        observerId = await queue.observe { [weak self] state in
            Task { @MainActor in
                self?.jobs = state.jobs
                if state.pausedForAuthentication { self?.needsRebind = true }
            }
        }
    }

    // MARK: 绑定

    func sendCode(phone: String) async throws -> SendCodeOutput {
        try await api.sendDeviceBindCode(phone: phone)
    }

    func bind(phone: String, code: String) async throws {
        let name = "\(UIDevice.current.model)（闻道）"
        let out = try await api.bindDevice(phone: phone, code: code, deviceName: name)
        try WendaoEnvironment.tokenStore.writeToken(out.deviceToken)
        isBound = true
        needsRebind = false
        await queue.resumeAfterAuthentication()
        pushCredentialsToWatch()
        kickUploads()
    }

    func unbind() {
        try? WendaoEnvironment.tokenStore.deleteToken()
        isBound = false
        pushCredentialsToWatch()
    }

    func updateBaseURL(_ url: URL) async {
        guard url != baseURL else { return }
        WendaoEnvironment.baseURL = url
        baseURL = url
        if let observerId { await queue.removeObserver(observerId) }
        observerId = nil
        api = Self.makeAPI(baseURL: url, upload: backgroundTransport)
        queue = Self.makeQueue(policy: policy, api: api)
        await attachQueueObserver()
        kickUploads()
    }

    private func pushCredentialsToWatch() {
        let token = (try? WendaoEnvironment.tokenStore.readToken()) ?? nil
        connectivity?.sendCredentials(WatchCredentials(deviceToken: token, baseURL: baseURL, issuedAt: Date()))
    }

    // MARK: 会话与上传

    func reloadSessions() {
        sessions = policy.store.allManifests()
    }

    func enqueue(_ clientSessionId: String) {
        let queue = self.queue
        Task {
            await queue.enqueue(clientSessionId)
            self.reloadSessions()
            self.kickUploads()
        }
    }

    func kickUploads() {
        guard isBound else { return }
        let queue = self.queue
        Task {
            let summary = await queue.runOnce()
            self.handle(summary)
        }
    }

    private func handle(_ summary: UploadRunSummary) {
        if summary.needsAuthentication { needsRebind = true }
        reloadSessions()
        wakeTask?.cancel()
        wakeTask = nil
        if let wake = summary.nextWake {
            let delay = max(1, wake.timeIntervalSinceNow)
            wakeTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.kickUploads()
            }
        }
        if !summary.finalized.isEmpty { startPollingMinutes() }
    }

    func retry(_ clientSessionId: String) {
        enqueue(clientSessionId)
    }

    func delete(_ clientSessionId: String) {
        guard recording.activeSessionId != clientSessionId else { return }
        let queue = self.queue
        Task {
            await queue.remove(clientSessionId)
            try? self.policy.store.deleteSession(clientSessionId)
            self.reloadSessions()
        }
    }

    // MARK: 手表中转

    private func receiveWatchSegment(_ meta: WatchSegmentMetadata, stagedFile: URL) {
        do {
            try policy.importSegment(meta, stagedFile: stagedFile)
            enqueue(meta.clientSessionId)
        } catch {
            try? FileManager.default.removeItem(at: stagedFile)
            lastError = "接收手表录音失败：\(error.localizedDescription)"
        }
    }

    private func receiveWatchSessionFinished(_ info: WatchSessionFinished) {
        do {
            try policy.markSessionFinished(info)
            enqueue(info.clientSessionId)
        } catch {
            lastError = "同步手表录音状态失败：\(error.localizedDescription)"
        }
    }

    // MARK: 妙记状态

    func displayState(for manifest: SessionManifest) -> SessionDisplayState {
        SessionDisplayState.derive(
            manifest: manifest, job: jobs[manifest.clientSessionId],
            minute: minuteStatuses[manifest.clientSessionId],
            isActiveRecording: recording.activeSessionId == manifest.clientSessionId)
    }

    func minuteToken(for clientSessionId: String) -> String? {
        jobs[clientSessionId]?.minuteToken
    }

    /// 已终结、妙记尚未完成的会话，每 15 秒查一次 `minute.status`。
    func startPollingMinutes() {
        guard pollTask == nil, isBound else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let pending = self.jobs.values.filter { job in
                    guard job.phase == .done, job.minuteId != nil else { return false }
                    return !(self.minuteStatuses[job.clientSessionId]?.status.isTerminal ?? false)
                }
                if pending.isEmpty {
                    self.pollTask = nil
                    return
                }
                for job in pending {
                    guard let minuteId = job.minuteId else { continue }
                    if let status = try? await self.api.minuteStatus(id: minuteId) {
                        self.minuteStatuses[job.clientSessionId] = status
                    }
                }
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func refreshMinuteStatus(_ clientSessionId: String) async {
        guard let id = jobs[clientSessionId]?.minuteId else { return }
        if let status = try? await api.minuteStatus(id: id) {
            minuteStatuses[clientSessionId] = status
        }
    }
}
