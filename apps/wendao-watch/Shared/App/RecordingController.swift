// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import AVFoundation
import Foundation
import Observation
import WendaoKit

#if os(watchOS)
    import WatchKit
#else
    import UIKit
#endif

/// 录音控制：会话 → 无缝分段 → 封口；标记此刻；来电、闹钟、Siri 打断后自动续录并记下中断；低电量自动收尾。
///
/// 手表与 iPhone 共用；分段封口与会话结束经回调交给各端的传输层（手表：WatchConnectivity / 直传；iPhone：上传队列）。
@MainActor
@Observable
final class RecordingController {
    enum Phase: Equatable {
        case idle
        case starting
        case recording
        /// 被打断，正在等待恢复。
        case interrupted
        case stopping
    }

    private(set) var phase: Phase = .idle
    private(set) var sessionStartedAt: Date?
    private(set) var level: Float = 0
    private(set) var segmentCount = 0
    /// 本次会话已记的标记数。
    private(set) var markCount = 0
    /// 最近一次标记的时刻（界面据此给出确认动效）。
    private(set) var lastMarkAt: Date?
    var alertMessage: String?

    var isRecording: Bool { phase == .recording || phase == .interrupted }
    var activeSessionId: String? { manifest?.clientSessionId }

    @ObservationIgnored var onSegmentSealed: ((SessionManifest, SegmentEntry) -> Void)?
    @ObservationIgnored var onSessionFinished: ((SessionManifest) -> Void)?
    @ObservationIgnored var onStatusChanged: ((RecordingStatusSnapshot) -> Void)?

    @ObservationIgnored let policy: SegmentRecorderPolicy
    @ObservationIgnored private let engine = GaplessAudioEngine()
    @ObservationIgnored private var manifest: SessionManifest?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var resumeTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var lastBatteryCheck = Date.distantPast
    @ObservationIgnored private var consecutiveEngineFailures = 0

    /// 电量低于此值自动收尾。
    static let lowBatteryThreshold: Float = 0.10
    /// 打断期间每隔多久试一次续录（打断结束的通知有时不来，例如 Siri；靠轮询保证 2 秒内续上）。
    static let resumeRetryInterval: Duration = .seconds(2)
    /// 打断超过这么久仍无法续录，保存并结束。
    static let maxInterruption: TimeInterval = 2 * 3600

    init(policy: SegmentRecorderPolicy) {
        self.policy = policy
        engine.setEventHandler { [weak self] event in
            guard let controller = self else { return }
            // 主队列 FIFO：保证「换段」通知按发生顺序处理
            DispatchQueue.main.async {
                MainActor.assumeIsolated { controller.handleEngineEvent(event) }
            }
        }
        observeAudioSession()
    }

    // MARK: 指令入口

    func handle(_ command: RecordingCommand) async {
        switch command {
        case .start: await start()
        case .stop: stop()
        case .toggle:
            if isRecording { stop() } else { await start() }
        case .mark:
            // Action Button：未在录则开始录，正在录则标记此刻
            if isRecording { mark(.actionButton) } else { await start() }
        }
    }

    func start(title: String? = nil) async {
        guard phase == .idle else { return }
        phase = .starting
        guard await AVAudioApplication.requestRecordPermission() else {
            phase = .idle
            alertMessage = "闻道没有麦克风权限，请在「设置」中允许后再录音"
            return
        }
        if let level = Self.batteryLevel(), level < Self.lowBatteryThreshold {
            phase = .idle
            alertMessage = "电量低于 10%，请充电后再录音"
            return
        }
        do {
            try activateAudioSession()
            let m = try policy.beginSession(startedAt: Date(), title: title)
            manifest = m
            sessionStartedAt = m.startedAt
            segmentCount = 0
            markCount = 0
            lastMarkAt = nil
            consecutiveEngineFailures = 0
            try startEngine()
            phase = .recording
            startTicker()
            publishStatus()
        } catch {
            alertMessage = "无法开始录音：\(error.localizedDescription)"
            if var m = manifest {
                try? policy.finishSession(&m, at: Date())
                onSessionFinished?(m)
            }
            reset()
        }
    }

    func stop(reason: String? = nil) {
        guard isRecording else { return }
        phase = .stopping
        resumeTask?.cancel()
        resumeTask = nil
        seal(engine.stop())
        if var m = manifest {
            try? policy.finishSession(&m, at: Date())
            manifest = m
            onSessionFinished?(m)
        }
        if let reason { alertMessage = reason }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        reset()
    }

    // MARK: 标记此刻

    /// 记一个标记（相对会话起点的毫秒）并轻触觉反馈。打断期间也可以标记。
    func mark(_ source: RecordingMarkSource) {
        guard isRecording, var m = manifest else { return }
        let added = (try? policy.addMark(source, at: Date(), in: &m)) ?? nil
        guard added != nil else { return }
        manifest = m
        markCount = m.marks.count
        lastMarkAt = Date()
        Self.playMarkHaptic()
    }

    // MARK: 分段

    /// 登记下一段并让引擎从这一段开始写。
    private func startEngine() throws {
        guard var m = manifest else { return }
        let (entry, _) = try policy.openSegment(in: &m)
        manifest = m
        let dir = policy.store.sessionDirectory(m.clientSessionId)
        let policy = self.policy
        let frames = Int(policy.segmentDuration * GaplessAudioEngine.sampleRate)
        do {
            try engine.start(firstSeq: entry.seq, framesPerSegment: frames) { seq in
                dir.appendingPathComponent(policy.fileName(forSeq: seq))
            }
        } catch {
            seal(engine.takeClosedSegments() + [ClosedSegment(seq: entry.seq, frames: 0, sampleRate: GaplessAudioEngine.sampleRate)])
            throw error
        }
    }

    /// 封存引擎交回的段：补登（引擎可能先建了文件）、算摘要、记精确时长；0 帧的段删除。已封存的跳过。
    private func seal(_ closed: [ClosedSegment]) {
        for c in closed.sorted(by: { $0.seq < $1.seq }) {
            guard var m = manifest else { return }
            if m.segment(seq: c.seq)?.sha256 != nil { continue }
            let id = m.clientSessionId
            do {
                try policy.registerSegment(seq: c.seq, in: &m)
                if c.frames == 0 {
                    let url = policy.store.sessionDirectory(id).appendingPathComponent(policy.fileName(forSeq: c.seq))
                    try? FileManager.default.removeItem(at: url)
                }
                let entry = try policy.sealSegment(seq: c.seq, durationMs: c.durationMs, in: &m)
                manifest = m
                if let entry {
                    segmentCount = m.sealedSegments.count
                    onSegmentSealed?(m, entry)
                }
            } catch {
                manifest = policy.store.loadIfPresent(id) ?? m
            }
        }
    }

    private func handleEngineEvent(_ event: GaplessAudioEngine.Event) {
        guard manifest != nil else {
            _ = engine.takeClosedSegments()
            return
        }
        switch event {
        case .rotated:
            let closed = engine.takeClosedSegments()
            seal(closed)
            // 引擎已在写下一段：立刻登记，进程被杀后恢复流程才找得到它
            if phase == .recording, let last = closed.max(by: { $0.seq < $1.seq }), var m = manifest {
                _ = try? policy.registerSegment(seq: last.seq + 1, in: &m)
                manifest = m
            }
            consecutiveEngineFailures = 0
            publishStatus()
        case .glitch(let from, let to):
            if var m = manifest {
                _ = try? policy.addGap(from: from, to: to, in: &m)
                manifest = m
            }
        case .failed(let message):
            guard phase == .recording else {
                seal(engine.takeClosedSegments())
                return
            }
            consecutiveEngineFailures += 1
            seal(engine.stop())
            if consecutiveEngineFailures >= 3 {
                stop(reason: "录音出错（\(message)），已保存已录部分")
                return
            }
            // 当作一次打断：记下中断，立即重启引擎开新段
            beginInterruption()
            scheduleResume(immediately: true)
        }
    }

    // MARK: 打断与恢复

    private func observeAudioSession() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) {
                [weak self] note in
                let raw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
                MainActor.assumeIsolated {
                    guard let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                    switch type {
                    case .began: self?.interruptionBegan()
                    case .ended: self?.interruptionEnded()
                    @unknown default: break
                    }
                }
            })
        observers.append(
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    // 媒体服务重置后旧引擎全部失效：按一次打断处理，立即用新引擎续录
                    self?.interruptionBegan()
                    self?.interruptionEnded()
                }
            })
    }

    private func interruptionBegan() {
        guard phase == .recording else { return }
        // 系统已停掉引擎：把已录部分封口，记下中断开始；恢复后开新段
        seal(engine.stop())
        beginInterruption()
        scheduleResume(immediately: false)
    }

    private func beginInterruption() {
        if var m = manifest {
            try? policy.beginGap(at: Date(), in: &m)
            manifest = m
        }
        level = 0
        phase = .interrupted
        publishStatus()
    }

    private func interruptionEnded() {
        guard phase == .interrupted else { return }
        scheduleResume(immediately: true)
    }

    /// 续录循环：打断结束的通知一到立即试；通知没来也每 2 秒试一次，直到续上或超过上限。
    private func scheduleResume(immediately: Bool) {
        resumeTask?.cancel()
        let deadline = Date().addingTimeInterval(Self.maxInterruption)
        resumeTask = Task { [weak self] in
            var skipWait = immediately
            while !Task.isCancelled {
                if !skipWait { try? await Task.sleep(for: Self.resumeRetryInterval) }
                skipWait = false
                guard let self, self.phase == .interrupted, !Task.isCancelled else { return }
                if self.tryResume() { return }
                if Date() > deadline {
                    self.stop(reason: "录音被其他应用长时间占用，已保存并结束")
                    return
                }
            }
        }
    }

    /// 重新激活音频会话、开新段；成功则把进行中的中断记为一条 gap。
    private func tryResume() -> Bool {
        do {
            try activateAudioSession()
            try startEngine()
        } catch {
            return false
        }
        if var m = manifest {
            _ = try? policy.endGap(at: Date(), in: &m)
            manifest = m
        }
        phase = .recording
        resumeTask = nil
        publishStatus()
        return true
    }

    /// App 回到前台时调用：若仍处于打断状态，立即再试一次恢复。
    func resumeIfInterrupted() {
        if phase == .interrupted { scheduleResume(immediately: true) }
    }

    private func activateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default, options: [])
        try session.setActive(true)
    }

    // MARK: 计时、电平与电量

    private func startTicker() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func tick() {
        level = phase == .recording ? engine.normalizedLevel : 0
        let now = Date()
        guard now.timeIntervalSince(lastBatteryCheck) >= 30 else { return }
        lastBatteryCheck = now
        if let battery = Self.batteryLevel(), battery < Self.lowBatteryThreshold {
            stop(reason: "电量低于 10%，已自动保存并结束录音")
        }
    }

    /// 0…1；无法读取时为 nil（模拟器返回 -1）。
    static func batteryLevel() -> Float? {
        #if os(watchOS)
            let device = WKInterfaceDevice.current()
            device.isBatteryMonitoringEnabled = true
            let level = device.batteryLevel
        #else
            let device = UIDevice.current
            device.isBatteryMonitoringEnabled = true
            let level = device.batteryLevel
        #endif
        return level >= 0 ? level : nil
    }

    private static func playMarkHaptic() {
        #if os(watchOS)
            WKInterfaceDevice.current().play(.click)
        #else
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }

    private func publishStatus() {
        let snapshot = RecordingStatusSnapshot(
            isRecording: isRecording, startedAt: isRecording ? sessionStartedAt : nil,
            pendingSegments: 0, updatedAt: Date())
        snapshot.save()
        onStatusChanged?(snapshot)
    }

    private func reset() {
        tickTask?.cancel()
        tickTask = nil
        resumeTask?.cancel()
        resumeTask = nil
        manifest = nil
        sessionStartedAt = nil
        level = 0
        phase = .idle
        publishStatus()
    }
}
