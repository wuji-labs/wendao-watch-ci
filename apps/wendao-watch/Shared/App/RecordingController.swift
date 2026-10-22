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

/// 录音控制：会话 → 分段 → 封口；处理来电、闹钟、Siri 打断后自动续录，低电量自动收尾。
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
    var alertMessage: String?

    var isRecording: Bool { phase == .recording || phase == .interrupted }
    var activeSessionId: String? { manifest?.clientSessionId }

    @ObservationIgnored var onSegmentSealed: ((SessionManifest, SegmentEntry) -> Void)?
    @ObservationIgnored var onSessionFinished: ((SessionManifest) -> Void)?
    @ObservationIgnored var onStatusChanged: ((RecordingStatusSnapshot) -> Void)?

    @ObservationIgnored let policy: SegmentRecorderPolicy
    @ObservationIgnored private let recorder = AudioSegmentRecorder()
    @ObservationIgnored private var manifest: SessionManifest?
    @ObservationIgnored private var currentSeq: Int?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var resumeTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var lastBatteryCheck = Date.distantPast

    /// 电量低于此值自动收尾。
    static let lowBatteryThreshold: Float = 0.10

    init(policy: SegmentRecorderPolicy) {
        self.policy = policy
        recorder.onReachedMaxDuration = { [weak self] in self?.rotateAfterMaxDuration() }
        recorder.onEncodeError = { [weak self] message in self?.handleEncodeError(message) }
        observeAudioSession()
    }

    // MARK: 指令入口

    func handle(_ command: RecordingCommand) async {
        switch command {
        case .start: await start()
        case .stop: stop()
        case .toggle:
            if isRecording { stop() } else { await start() }
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
            try openNextSegment()
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
        sealCurrentSegment(measured: recorder.stop())
        if var m = manifest {
            try? policy.finishSession(&m, at: Date())
            manifest = m
            onSessionFinished?(m)
        }
        if let reason { alertMessage = reason }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        reset()
    }

    // MARK: 分段

    private func openNextSegment() throws {
        guard var m = manifest else { return }
        let (entry, url) = try policy.openSegment(in: &m)
        manifest = m
        currentSeq = entry.seq
        try recorder.start(url: url, maxDuration: policy.segmentDuration)
    }

    private func sealCurrentSegment(measured: TimeInterval) {
        guard let seq = currentSeq, var m = manifest else { return }
        currentSeq = nil
        let measuredMs = Int((measured * 1000).rounded())
        let id = m.clientSessionId
        do {
            if let entry = try policy.sealSegment(seq: seq, durationMs: measuredMs > 0 ? measuredMs : nil, in: &m) {
                manifest = m
                segmentCount = m.sealedSegments.count
                onSegmentSealed?(m, entry)
                refineDuration(sessionId: id, entry: entry)
            } else {
                manifest = m
            }
        } catch {
            manifest = policy.store.loadIfPresent(id) ?? m
        }
    }

    /// 计时值不精确时（系统按时长自动停止后 currentTime 归零），用文件真实时长校正清单。
    private func refineDuration(sessionId: String, entry: SegmentEntry) {
        let url = policy.store.fileURL(for: entry, in: sessionId)
        let store = policy.store
        let seq = entry.seq
        Task.detached(priority: .utility) {
            guard let ms = await AudioDuration.probe(url) else { return }
            _ = try? store.update(sessionId) { m in
                m.updateSegment(seq: seq) { $0.durationMs = ms }
            }
        }
    }

    private func rotateAfterMaxDuration() {
        guard phase == .recording else { return }
        sealCurrentSegment(measured: policy.segmentDuration)
        do {
            try openNextSegment()
        } catch {
            stop(reason: "切换分段失败，已保存并结束录音：\(error.localizedDescription)")
        }
        publishStatus()
    }

    private func handleEncodeError(_ message: String) {
        guard isRecording else { return }
        sealCurrentSegment(measured: recorder.stop())
        do {
            try openNextSegment()
        } catch {
            stop(reason: "录音出错（\(message)），已保存已录部分")
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
                    self?.interruptionBegan()
                    self?.interruptionEnded()
                }
            })
    }

    private func interruptionBegan() {
        guard phase == .recording else { return }
        // 系统已暂停录音：先把已录部分封口，恢复后开新段
        sealCurrentSegment(measured: recorder.stop())
        phase = .interrupted
        publishStatus()
    }

    private func interruptionEnded() {
        guard phase == .interrupted else { return }
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            // 来电挂断后音频会话可能还被占用，最多重试约 30 秒
            for attempt in 0..<15 {
                guard let self, self.phase == .interrupted, !Task.isCancelled else { return }
                do {
                    try self.activateAudioSession()
                    try self.openNextSegment()
                    self.phase = .recording
                    self.publishStatus()
                    return
                } catch {
                    try? await Task.sleep(for: .seconds(attempt < 5 ? 1 : 3))
                }
            }
            self?.stop(reason: "录音被其他应用占用，已保存并结束")
        }
    }

    /// App 回到前台时调用：若仍处于打断状态，立即再试一次恢复。
    func resumeIfInterrupted() {
        if phase == .interrupted { interruptionEnded() }
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
        level = recorder.normalizedLevel()
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
        currentSeq = nil
        sessionStartedAt = nil
        level = 0
        phase = .idle
        publishStatus()
    }
}
