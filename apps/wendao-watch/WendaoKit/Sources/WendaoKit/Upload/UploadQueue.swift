// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// 指数退避：第 n 次失败后等待 `base × multiplier^(n-1)`，封顶 `maxDelay`，再加抖动。永不放弃。
public struct RetryPolicy: Sendable {
    public var baseDelay: TimeInterval
    public var multiplier: Double
    public var maxDelay: TimeInterval
    /// 抖动比例上限（0.2 = 最多再加 20%）。
    public var jitterRatio: Double
    /// 0…1 的随机数源，测试中固定。
    public var random: @Sendable () -> Double

    public init(
        baseDelay: TimeInterval = 2, multiplier: Double = 2, maxDelay: TimeInterval = 30 * 60,
        jitterRatio: Double = 0.2, random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }
    ) {
        self.baseDelay = baseDelay
        self.multiplier = multiplier
        self.maxDelay = maxDelay
        self.jitterRatio = jitterRatio
        self.random = random
    }

    public func delay(afterFailures failures: Int) -> TimeInterval {
        let n = max(failures, 1)
        let raw = baseDelay * pow(multiplier, Double(n - 1))
        let capped = min(raw, maxDelay)
        return capped * (1 + jitterRatio * min(max(random(), 0), 1))
    }
}

/// 一个会话的上传进度，持久化在队列状态文件里。
public struct UploadJob: Codable, Sendable, Equatable, Identifiable {
    public enum Phase: String, Codable, Sendable {
        /// 正在上传或等待重试。
        case uploading
        /// 已终结，服务端已生成妙记。
        case done
        /// 服务端以 409 判定某段内容冲突：客户端数据损坏，停止该会话，等待人工处理。
        case corrupted
        /// 本地清单无法修复（缺失或序号断档）。
        case failed
    }

    public var clientSessionId: String
    public var serverSessionId: String?
    public var phase: Phase
    public var consecutiveFailures: Int
    public var nextAttemptAt: Date?
    public var lastError: String?
    public var minuteId: String?
    public var minuteToken: String?
    public var corruptedSeqs: [Int]
    public var updatedAt: Date

    public var id: String { clientSessionId }

    public init(clientSessionId: String, now: Date) {
        self.clientSessionId = clientSessionId
        self.serverSessionId = nil
        self.phase = .uploading
        self.consecutiveFailures = 0
        self.nextAttemptAt = nil
        self.lastError = nil
        self.minuteId = nil
        self.minuteToken = nil
        self.corruptedSeqs = []
        self.updatedAt = now
    }

    public var isActive: Bool { phase == .uploading }
}

public struct UploadQueueState: Codable, Sendable, Equatable {
    public var version: Int = 1
    public var jobs: [String: UploadJob] = [:]
    /// 服务端返回 401 后暂停全部上传，直到重新绑定。
    public var pausedForAuthentication: Bool = false

    public init() {}
}

/// 一轮处理的结果。
public struct UploadRunSummary: Sendable, Equatable {
    public var processed: [String] = []
    public var finalized: [String] = []
    public var uploadedSegments = 0
    public var needsAuthentication = false
    /// 最早的下次重试时间；nil 表示没有待重试的任务。
    public var nextWake: Date?
}

/// 分段上传队列：按 W1 协议 begin → 查 `recording.status` 补缺 → 逐段上传（sha256 幂等）→ finalize。
///
/// - 以服务端 `recording.status` 为唯一真相：每轮先对账再补传，后台上传在进程被杀后完成也不会重复传。
/// - 409 视为客户端数据损坏：标记分段与会话，不再重试。
/// - 网络、5xx、429 退避重试；401 暂停全队列等待重新绑定。
/// - 状态写盘，进程重启后从断点继续。
public actor UploadQueue {
    private let store: ManifestStore
    private let backend: any RecordingBackend
    private let stateURL: URL
    private let retry: RetryPolicy
    private let clock: WendaoClock
    private var state: UploadQueueState
    private var running = false
    private var rerunRequested = false
    private var observers: [UUID: @Sendable (UploadQueueState) -> Void] = [:]

    public init(
        store: ManifestStore, backend: any RecordingBackend, stateURL: URL,
        retry: RetryPolicy = RetryPolicy(), clock: WendaoClock = .system
    ) {
        self.store = store
        self.backend = backend
        self.stateURL = stateURL
        self.retry = retry
        self.clock = clock
        if let data = try? Data(contentsOf: stateURL),
            let decoded = try? WendaoJSON.decoder().decode(UploadQueueState.self, from: data)
        {
            self.state = decoded
        } else {
            self.state = UploadQueueState()
        }
    }

    // MARK: 查询

    public var snapshot: UploadQueueState { state }

    public func job(_ clientSessionId: String) -> UploadJob? { state.jobs[clientSessionId] }

    @discardableResult
    public func observe(_ handler: @escaping @Sendable (UploadQueueState) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        handler(state)
        return id
    }

    public func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    // MARK: 控制

    /// 登记一个会话（重复登记无副作用）；已在退避中的会话立即可重试。
    public func enqueue(_ clientSessionId: String) {
        let now = clock.now()
        if var job = state.jobs[clientSessionId] {
            if job.isActive {
                job.nextAttemptAt = nil
                job.updatedAt = now
                state.jobs[clientSessionId] = job
            }
        } else {
            state.jobs[clientSessionId] = UploadJob(clientSessionId: clientSessionId, now: now)
        }
        persist()
    }

    /// 重新绑定后恢复。
    public func resumeAfterAuthentication() {
        state.pausedForAuthentication = false
        for (id, var job) in state.jobs where job.isActive {
            job.nextAttemptAt = nil
            state.jobs[id] = job
        }
        persist()
    }

    /// 网络恢复等时机：清空退避，下一轮立即重试。
    public func retryNow() {
        for (id, var job) in state.jobs where job.isActive {
            job.nextAttemptAt = nil
            state.jobs[id] = job
        }
        persist()
    }

    public func remove(_ clientSessionId: String) {
        state.jobs[clientSessionId] = nil
        persist()
    }

    /// 处理所有到期任务一轮。并发调用时只跑一个循环，后来者合并到下一轮。
    @discardableResult
    public func runOnce() async -> UploadRunSummary {
        if running {
            rerunRequested = true
            return UploadRunSummary(nextWake: nextWake())
        }
        running = true
        defer { running = false }
        var summary = UploadRunSummary()
        repeat {
            rerunRequested = false
            await pass(&summary)
        } while rerunRequested && !state.pausedForAuthentication
        summary.needsAuthentication = state.pausedForAuthentication
        summary.nextWake = nextWake()
        return summary
    }

    /// 持续处理直到没有活跃任务或需要重新绑定；在两轮之间按最早的重试时间休眠。
    public func drain(sleep: @Sendable (TimeInterval) async throws -> Void) async {
        while !Task.isCancelled {
            let summary = await runOnce()
            guard !summary.needsAuthentication, let wake = summary.nextWake else { return }
            let interval = max(0, wake.timeIntervalSince(clock.now()))
            do { try await sleep(interval) } catch { return }
        }
    }

    public func nextWake() -> Date? {
        state.jobs.values.filter(\.isActive).compactMap(\.nextAttemptAt).min()
    }

    // MARK: 处理

    private func pass(_ summary: inout UploadRunSummary) async {
        guard !state.pausedForAuthentication else { return }
        let now = clock.now()
        let due = state.jobs.values
            .filter { $0.isActive && ($0.nextAttemptAt.map { $0 <= now } ?? true) }
            .sorted { $0.updatedAt < $1.updatedAt }
        for job in due {
            if state.pausedForAuthentication { break }
            summary.processed.append(job.clientSessionId)
            await process(job.clientSessionId, summary: &summary)
        }
    }

    private func process(_ id: String, summary: inout UploadRunSummary) async {
        guard var job = state.jobs[id] else { return }
        guard var manifest = store.loadIfPresent(id) else {
            job.phase = .failed
            job.lastError = "本地录音清单丢失"
            save(job)
            return
        }
        do {
            let sessionId: String
            if let existing = job.serverSessionId {
                sessionId = existing
            } else {
                let out = try await backend.beginRecording(
                    RecordingBeginInput(
                        title: manifest.title, startedAt: manifest.startedAt, language: manifest.language,
                        clientSessionId: manifest.clientSessionId))
                sessionId = out.sessionId
                job.serverSessionId = sessionId
                save(job)
            }

            // 最多两轮：终结报缺段时重新对账补传一次
            for round in 0..<2 {
                let status = try await backend.recordingStatus(sessionId: sessionId)
                let received = Set(status.receivedSeqs)
                manifest = try reconcile(manifest, received: received)
                if let minute = status.finalizedMinute {
                    // 另一端（手表直传或 iPhone 中转）已经终结过
                    complete(&job, with: minute, summary: &summary)
                    return
                }

                for segment in manifest.sealedSegments where !received.contains(segment.seq) {
                    guard let sha = segment.sha256 else { continue }
                    let url = store.fileURL(for: segment, in: id)
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        throw LocalFailure.missingFile(segment.seq)
                    }
                    do {
                        try await backend.uploadSegment(
                            SegmentUpload(
                                sessionId: sessionId, seq: segment.seq, sha256: sha, fileURL: url,
                                fileName: segment.path))
                    } catch WendaoAPIError.conflict {
                        throw LocalFailure.conflict(segment.seq)
                    } catch WendaoAPIError.sessionClosed {
                        // 会话已终结或正在合成：下一轮从 status 取结果
                        throw LocalFailure.sessionClosed
                    }
                    manifest = try store.update(id) { m in
                        m.updateSegment(seq: segment.seq) { $0.uploaded = true }
                    }
                    summary.uploadedSegments += 1
                }

                guard manifest.isFinished else {
                    // 仍在录：已封口的段都已上传，等下一段
                    job.consecutiveFailures = 0
                    job.lastError = nil
                    job.nextAttemptAt = nil
                    job.phase = .uploading
                    save(job, idle: true)
                    return
                }
                guard manifest.sealedSegmentsAreContiguous else {
                    throw LocalFailure.sequenceGap
                }
                guard manifest.isReadyToFinalize else {
                    // 手表的分段还没收齐（或仍有未封口段），等待
                    job.consecutiveFailures = 0
                    job.lastError = nil
                    save(job, idle: true)
                    return
                }

                do {
                    let out = try await backend.finalizeRecording(
                        sessionId: sessionId, expectedSegments: manifest.sealedSegments.count)
                    complete(&job, with: out, summary: &summary)
                    return
                } catch WendaoAPIError.preconditionFailed(let message) {
                    if round == 1 { throw WendaoAPIError.preconditionFailed(message) }
                    continue
                }
            }
        } catch let failure as LocalFailure {
            switch failure {
            case .conflict(let seq):
                _ = try? store.update(id) { m in
                    m.updateSegment(seq: seq) {
                        $0.corrupted = true
                        $0.uploaded = false
                    }
                }
                job.phase = .corrupted
                if !job.corruptedSeqs.contains(seq) { job.corruptedSeqs.append(seq) }
                job.lastError = "第 \(seq + 1) 段与服务端已收内容不一致，录音数据可能已损坏"
            case .missingFile(let seq):
                job.phase = .failed
                job.lastError = "第 \(seq + 1) 段音频文件丢失"
            case .sequenceGap:
                job.phase = .failed
                job.lastError = "录音分段不连续，无法合成"
            case .sessionClosed:
                scheduleRetry(&job, message: WendaoAPIError.sessionClosed("").userMessage)
                save(job)
                return
            }
            job.nextAttemptAt = nil
            save(job)
        } catch WendaoAPIError.unauthorized {
            job.lastError = WendaoAPIError.unauthorized.userMessage
            state.pausedForAuthentication = true
            save(job)
        } catch WendaoAPIError.notFound {
            // 服务端找不到会话（可能被清理）：丢弃会话号，下一轮重新 begin（以 clientSessionId 幂等）
            job.serverSessionId = nil
            scheduleRetry(&job, message: "服务端会话不存在，将重新建立")
            save(job)
        } catch {
            let apiError = error as? WendaoAPIError ?? .transport(error.localizedDescription)
            scheduleRetry(&job, message: apiError.userMessage)
            save(job)
        }
    }

    private enum LocalFailure: Error {
        case conflict(Int)
        case missingFile(Int)
        case sequenceGap
        case sessionClosed
    }

    private func complete(
        _ job: inout UploadJob, with minute: RecordingFinalizeOutput, summary: inout UploadRunSummary
    ) {
        job.phase = .done
        job.minuteId = minute.minuteId
        job.minuteToken = minute.token
        job.consecutiveFailures = 0
        job.lastError = nil
        job.nextAttemptAt = nil
        save(job)
        summary.finalized.append(job.clientSessionId)
    }

    private func scheduleRetry(_ job: inout UploadJob, message: String) {
        job.consecutiveFailures += 1
        job.lastError = message
        job.nextAttemptAt = clock.now().addingTimeInterval(retry.delay(afterFailures: job.consecutiveFailures))
    }

    /// 以服务端已收列表校正本地 `uploaded` 标记。
    private func reconcile(_ manifest: SessionManifest, received: Set<Int>) throws -> SessionManifest {
        let needsChange = manifest.segments.contains {
            $0.uploaded != (received.contains($0.seq) && $0.isSealed)
        }
        guard needsChange else { return manifest }
        return try store.update(manifest.clientSessionId) { m in
            for i in m.segments.indices {
                m.segments[i].uploaded = received.contains(m.segments[i].seq) && m.segments[i].isSealed
            }
        }
    }

    /// `idle`：本轮无事可做（等录音继续或等手表补段），不安排定时重试，由新事件 `enqueue` 唤醒。
    private func save(_ job: UploadJob, idle: Bool = false) {
        var j = job
        if idle { j.nextAttemptAt = nil }
        j.updatedAt = clock.now()
        state.jobs[j.clientSessionId] = j
        persist()
    }

    private func persist() {
        if let data = try? WendaoJSON.encoder().encode(state) {
            try? FileManager.writeAtomically(data, to: stateURL)
        }
        let snapshot = state
        for handler in observers.values { handler(snapshot) }
    }
}
