// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import Foundation

/// 测分段时长（毫秒）。返回 nil 表示文件无法解析（例如录制中途进程被杀、容器未写完）。
public typealias AudioDurationProbe = @Sendable (URL) async -> Int?

public enum SegmentPolicyError: Error, Sendable, Equatable {
    case segmentNotOpen(Int)
    case sessionAlreadyFinished
}

/// 一次恢复的结果，供界面与日志说明发生了什么。
public struct RecoveryReport: Sendable, Equatable {
    public var clientSessionId: String
    /// 补齐摘要与时长、重新可用的分段。
    public var recoveredSeqs: [Int]
    /// 磁盘上存在但清单里没有的分段，已补登。
    public var adoptedSeqs: [Int]
    /// 无法解析、已标记损坏的分段。
    public var corruptedSeqs: [Int]
    /// 清单登记但文件不存在、已移除的分段。
    public var droppedSeqs: [Int]
    /// 会话原本未收尾，已由恢复流程收尾。
    public var closedSession: Bool

    public var changedAnything: Bool {
        !recoveredSeqs.isEmpty || !adoptedSeqs.isEmpty || !corruptedSeqs.isEmpty
            || !droppedSeqs.isEmpty || closedSession
    }
}

/// 切段策略：5 分钟一段、段文件命名、清单读写与崩溃后恢复。
///
/// 纯逻辑，不依赖 AVFoundation；真正的录音器只负责把声音写进 `fileURL` 给出的文件。
public struct SegmentRecorderPolicy: Sendable {
    public var segmentDuration: TimeInterval
    public var fileExtension: String
    public let store: ManifestStore
    /// 本机录音的来源标识；恢复时只替本机录的会话收尾。
    public let localSource: RecordingSource

    public init(
        store: ManifestStore, localSource: RecordingSource, segmentDuration: TimeInterval = 300,
        fileExtension: String = "m4a"
    ) {
        self.store = store
        self.localSource = localSource
        self.segmentDuration = segmentDuration
        self.fileExtension = fileExtension
    }

    // MARK: 命名

    public func fileName(forSeq seq: Int) -> String {
        let digits = String(seq)
        let padded = String(repeating: "0", count: max(0, 5 - digits.count)) + digits
        return "seg-\(padded).\(fileExtension)"
    }

    /// 从文件名反解序号；不是本策略生成的文件返回 nil。
    public func seq(fromFileName name: String) -> Int? {
        let suffix = ".\(fileExtension)"
        guard name.hasPrefix("seg-"), name.hasSuffix(suffix) else { return nil }
        let core = name.dropFirst(4).dropLast(suffix.count)
        guard !core.isEmpty, core.allSatisfy(\.isNumber) else { return nil }
        return Int(core)
    }

    public func shouldRotate(segmentStartedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(segmentStartedAt) >= segmentDuration
    }

    public func nextSeq(in manifest: SessionManifest) -> Int {
        (manifest.segments.map(\.seq).max() ?? -1) + 1
    }

    // MARK: 会话生命周期

    public func beginSession(
        startedAt: Date, title: String? = nil, language: String = "zh"
    ) throws -> SessionManifest {
        let m = SessionManifest(startedAt: startedAt, title: title, language: language, source: localSource)
        try FileManager.default.createDirectory(
            at: store.sessionDirectory(m.clientSessionId), withIntermediateDirectories: true)
        try store.save(m)
        return m
    }

    /// 登记一个新分段（先落清单再开始录音，崩溃后才能找到它），返回录音器应写入的文件。
    public func openSegment(in manifest: inout SessionManifest) throws -> (SegmentEntry, URL) {
        var opened: SegmentEntry?
        manifest = try store.update(manifest.clientSessionId) { m in
            guard !m.isFinished else { throw SegmentPolicyError.sessionAlreadyFinished }
            let seq = nextSeq(in: m)
            let entry = SegmentEntry(seq: seq, path: fileName(forSeq: seq))
            m.upsert(entry)
            opened = entry
        }
        guard let entry = opened else { throw SegmentPolicyError.sessionAlreadyFinished }
        return (entry, store.fileURL(for: entry, in: manifest.clientSessionId))
    }

    /// 录音器停止后封口：算摘要、记时长。文件缺失或为空则从清单移除并返回 nil。
    @discardableResult
    public func sealSegment(
        seq: Int, durationMs: Int?, in manifest: inout SessionManifest
    ) throws -> SegmentEntry? {
        let id = manifest.clientSessionId
        let url = store.sessionDirectory(id).appendingPathComponent(fileName(forSeq: seq))
        var digest: String?
        if Self.fileSize(url) > 0 { digest = try FileDigest.sha256Hex(of: url) }
        manifest = try store.update(id) { m in
            guard m.segment(seq: seq) != nil else { throw SegmentPolicyError.segmentNotOpen(seq) }
            if let digest {
                m.updateSegment(seq: seq) {
                    $0.sha256 = digest
                    $0.durationMs = durationMs
                }
            } else {
                m.segments.removeAll { $0.seq == seq }
            }
        }
        if digest == nil { try? FileManager.default.removeItem(at: url) }
        return digest == nil ? nil : manifest.segment(seq: seq)
    }

    public func finishSession(_ manifest: inout SessionManifest, at date: Date) throws {
        manifest = try store.update(manifest.clientSessionId) { $0.finishedAt = date }
    }

    // MARK: 接收来自手表的分段（iPhone 侧）

    /// 把从手表收到的分段文件并入本机清单（会话不存在则新建）。
    ///
    /// 摘要与元数据不一致说明传输损坏：分段登记为损坏、不上传，等待手表重传或直传覆盖。
    @discardableResult
    public func importSegment(
        _ meta: WatchSegmentMetadata, stagedFile: URL
    ) throws -> SegmentEntry {
        let id = meta.clientSessionId
        try ManifestStore.validate(id)
        try FileManager.default.createDirectory(
            at: store.sessionDirectory(id), withIntermediateDirectories: true)
        let name = fileName(forSeq: meta.seq)
        let dest = store.sessionDirectory(id).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: stagedFile, to: dest)
        let actual = try FileDigest.sha256Hex(of: dest)
        let matches = actual == meta.sha256.lowercased()

        var result = SegmentEntry(seq: meta.seq, path: name)
        try store.modify(
            id,
            orCreate: {
                SessionManifest(
                    clientSessionId: id, startedAt: meta.sessionStartedAt, title: meta.title,
                    language: meta.language, source: .watch)
            }
        ) { m in
            let previous = m.segment(seq: meta.seq)
            let keepUploaded = matches && previous?.sha256 == actual && (previous?.uploaded ?? false)
            result = SegmentEntry(
                seq: meta.seq, path: name, sha256: actual, durationMs: meta.durationMs,
                uploaded: keepUploaded, transferred: true, corrupted: !matches)
            m.upsert(result)
        }
        return result
    }

    /// 手表告知会话已结束。只在已收齐或晚到的分段到达后才影响上传终结。
    public func markSessionFinished(_ info: WatchSessionFinished) throws {
        let id = info.clientSessionId
        try store.modify(
            id,
            orCreate: {
                SessionManifest(
                    clientSessionId: id, startedAt: info.sessionStartedAt, title: info.title,
                    language: info.language, source: .watch)
            }
        ) { m in
            m.finishedAt = info.finishedAt
            m.expectedSegmentCount = info.segmentCount
        }
    }

    // MARK: 崩溃恢复

    /// 扫描全部会话，修复进程被杀留下的半截状态。`activeSessionId` 是本进程正在录的会话，跳过。
    ///
    /// - 未封口的分段：能解析则补摘要与时长；不能解析则标记损坏（保留文件，不上传）。
    /// - 清单缺登的段文件：补登后同上处理。
    /// - 登记了但文件不存在的分段：移除。
    /// - 未收尾的会话：以最后一段的结束时间收尾。
    public func recover(
        activeSessionId: String? = nil, probe: AudioDurationProbe, now: Date
    ) async -> [RecoveryReport] {
        var reports: [RecoveryReport] = []
        for id in store.sessionIds() where id != activeSessionId {
            guard var manifest = store.loadIfPresent(id) else { continue }
            var report = RecoveryReport(
                clientSessionId: id, recoveredSeqs: [], adoptedSeqs: [], corruptedSeqs: [],
                droppedSeqs: [], closedSession: false)
            let dir = store.sessionDirectory(id)

            // 补登磁盘上的孤儿段文件
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in files {
                guard let n = self.seq(fromFileName: name), manifest.segment(seq: n) == nil else { continue }
                manifest.upsert(SegmentEntry(seq: n, path: name))
                report.adoptedSeqs.append(n)
            }

            for entry in manifest.segments {
                let url = store.fileURL(for: entry, in: id)
                let size = Self.fileSize(url)
                if size == 0 {
                    // 未封口且为空（或不存在）：这一段从未真正写入。已封口的段文件可能已按保留策略清理，不动。
                    if entry.sha256 == nil {
                        manifest.segments.removeAll { $0.seq == entry.seq }
                        try? FileManager.default.removeItem(at: url)
                        report.droppedSeqs.append(entry.seq)
                        report.adoptedSeqs.removeAll { $0 == entry.seq }
                    }
                    continue
                }
                guard entry.sha256 == nil, !entry.corrupted else { continue }
                if let duration = await probe(url), duration > 0, let digest = try? FileDigest.sha256Hex(of: url) {
                    manifest.updateSegment(seq: entry.seq) {
                        $0.sha256 = digest
                        $0.durationMs = duration
                    }
                    if !report.adoptedSeqs.contains(entry.seq) { report.recoveredSeqs.append(entry.seq) }
                } else {
                    manifest.updateSegment(seq: entry.seq) { $0.corrupted = true }
                    report.corruptedSeqs.append(entry.seq)
                    report.adoptedSeqs.removeAll { $0 == entry.seq }
                }
            }

            // 只有本机录的会话才由本机收尾；从手表收来的会话由手表的「结束」消息收尾
            if manifest.finishedAt == nil, manifest.source == localSource {
                let elapsedMs = manifest.sealedSegments.reduce(0) { $0 + ($1.durationMs ?? 0) }
                let estimated = manifest.startedAt.addingTimeInterval(Double(elapsedMs) / 1000)
                manifest.finishedAt = min(max(estimated, manifest.startedAt), now)
                manifest.recoveredAfterCrash = true
                report.closedSession = true
            }

            if report.changedAnything {
                try? store.save(manifest)
                reports.append(report)
            }
        }
        return reports
    }

    static func fileSize(_ url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.intValue ?? 0
    }
}
