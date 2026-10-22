// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import SwiftUI
import WendaoKit

struct SessionListView: View {
    @Environment(AppModel.self) private var model
    @State private var showRecorder = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                if model.needsRebind {
                    Section {
                        NavigationLink {
                            BindView()
                        } label: {
                            Label("绑定已失效，上传已暂停。点此重新绑定", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                if model.sessions.isEmpty {
                    ContentUnavailableView(
                        "还没有录音", systemImage: "waveform",
                        description: Text("在 Apple Watch 上抬腕点按录音，或点右上角在手机上直接录。"))
                } else {
                    ForEach(model.sessions) { manifest in
                        NavigationLink(value: manifest.clientSessionId) {
                            SessionRow(manifest: manifest, state: model.displayState(for: manifest))
                        }
                        .swipeActions {
                            if model.recording.activeSessionId != manifest.clientSessionId {
                                Button("删除", role: .destructive) { model.delete(manifest.clientSessionId) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("闻道")
            .navigationDestination(for: String.self) { id in
                SessionDetailView(clientSessionId: id)
            }
            .refreshable {
                model.reloadSessions()
                model.kickUploads()
                for m in model.sessions { await model.refreshMinuteStatus(m.clientSessionId) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("设置")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showRecorder = true } label: {
                        Image(systemName: model.recording.isRecording ? "record.circle.fill" : "mic.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .font(.title2)
                    }
                    .accessibilityLabel(model.recording.isRecording ? "正在录音" : "在手机上录音")
                }
            }
            .sheet(isPresented: $showRecorder) { PhoneRecorderView() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .alert(
                "提示",
                isPresented: Binding(
                    get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })
            ) {
                Button("好") { model.lastError = nil }
            } message: {
                Text(model.lastError ?? "")
            }
        }
    }
}

struct SessionRow: View {
    let manifest: SessionManifest
    let state: SessionDisplayState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: manifest.source == .watch ? "applewatch" : "iphone")
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(manifest.title?.isEmpty == false ? manifest.title! : manifest.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(DurationText.clock(ms: manifest.totalDurationMs))
                    if let detail = state.detail {
                        Text("·")
                        Text(detail).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            StateBadge(state: state)
        }
        .padding(.vertical, 2)
    }
}

struct StateBadge: View {
    let state: SessionDisplayState

    private var color: Color {
        switch state {
        case .recording: return .red
        case .uploading: return .blue
        case .transcribing: return .orange
        case .completed: return .green
        case .failed: return .gray
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            if case .recording = state {
                Circle().fill(.red).frame(width: 7, height: 7)
            }
            Text(state.label)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.15), in: Capsule())
        .foregroundStyle(color)
    }
}

/// 详情：按说话人分段的转写、摘要、章节、待办（来自 `minute.getByToken`）。
struct SessionDetailView: View {
    @Environment(AppModel.self) private var model
    let clientSessionId: String
    @State private var detail: MinuteDetail?
    @State private var loadError: String?
    @State private var tab = 0

    private var manifest: SessionManifest? {
        model.sessions.first { $0.clientSessionId == clientSessionId }
    }

    var body: some View {
        Group {
            if let detail, detail.minute.status == .ready {
                content(detail)
            } else if let manifest {
                ProcessingView(manifest: manifest, state: model.displayState(for: manifest), loadError: loadError) {
                    model.retry(clientSessionId)
                }
            } else {
                ContentUnavailableView("录音不存在", systemImage: "questionmark.circle")
            }
        }
        .navigationTitle(detail?.minute.title.isEmpty == false ? detail!.minute.title : "录音详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let token = model.minuteToken(for: clientSessionId) {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: model.api.webURL(minuteToken: token)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .task(id: model.minuteStatuses[clientSessionId]?.status) { await load() }
    }

    private func load() async {
        guard let token = model.minuteToken(for: clientSessionId) else { return }
        await model.refreshMinuteStatus(clientSessionId)
        guard model.minuteStatuses[clientSessionId]?.status == .ready else { return }
        do {
            detail = try await model.api.minuteDetail(token: token)
            loadError = nil
        } catch let e as WendaoAPIError {
            loadError = e.userMessage
        } catch {
            loadError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func content(_ d: MinuteDetail) -> some View {
        VStack(spacing: 0) {
            Picker("内容", selection: $tab) {
                Text("纪要").tag(0)
                Text("文字稿").tag(1)
            }
            .pickerStyle(.segmented)
            .padding()
            if tab == 0 { SummaryList(detail: d) } else { TranscriptList(detail: d) }
        }
    }
}

private struct SummaryList: View {
    let detail: MinuteDetail

    private var markNotes: [SessionTimeline.Annotation] {
        detail.timelineAnnotations.filter {
            if case .mark = $0.kind { return true }
            return false
        }
    }

    var body: some View {
        List {
            if !detail.marks.isEmpty {
                Section("我标记的时刻") {
                    ForEach(Array(markNotes.enumerated()), id: \.offset) { _, note in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "flag.fill").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(DurationText.clock(ms: note.audioMs)).monospacedDigit().font(.subheadline.weight(.semibold))
                                if let turn = detail.turn(atAudioMs: note.audioMs) {
                                    Text(turn.text).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                                }
                            }
                        }
                    }
                }
            }
            if let s = detail.summary, !s.overview.isEmpty {
                Section("摘要") {
                    Text(s.overview)
                    ForEach(Array(s.keyPoints.enumerated()), id: \.offset) { _, p in
                        Label(p.text, systemImage: "smallcircle.filled.circle")
                    }
                }
            }
            if !detail.chapters.isEmpty {
                Section("章节") {
                    ForEach(detail.chapters.sorted { $0.orderIndex < $1.orderIndex }) { c in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(DurationText.clock(ms: c.startMs)).monospacedDigit().foregroundStyle(.secondary)
                                Text(c.title).font(.headline)
                            }
                            if !c.summary.isEmpty { Text(c.summary).font(.subheadline).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            if !detail.todos.isEmpty {
                Section("待办") {
                    ForEach(detail.todos.sorted { $0.orderIndex < $1.orderIndex }) { t in
                        HStack(alignment: .top) {
                            Image(systemName: t.status == "DONE" ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(t.status == "DONE" ? .green : .secondary)
                            VStack(alignment: .leading) {
                                Text(t.text)
                                if let owner = t.owner, !owner.isEmpty {
                                    Text(owner).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            Section {
                Text("文字稿、摘要与待办由人工智能生成，请以原始录音为准。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct TranscriptList: View {
    let detail: MinuteDetail

    var body: some View {
        List(detail.transcriptRows) { row in
            switch row {
            case .turn(let turn):
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Circle()
                            .fill(Color(hex: turn.speaker?.colorHex) ?? .accentColor)
                            .frame(width: 8, height: 8)
                        Text(turn.speaker?.displayName ?? "未知说话人").font(.subheadline.weight(.semibold))
                        Text(DurationText.clock(ms: turn.startMs)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Text(turn.text).textSelection(.enabled)
                }
                .padding(.vertical, 4)
            case .annotation(let note, _):
                TimelineNoteRow(note: note)
            }
        }
        .listStyle(.plain)
    }
}

/// 文字稿里的标注：「标记」或「此处中断 N 秒」。
private struct TimelineNoteRow: View {
    let note: SessionTimeline.Annotation

    var body: some View {
        switch note.kind {
        case .mark:
            Label {
                Text("标记 · \(DurationText.clock(ms: note.audioMs))").monospacedDigit()
            } icon: {
                Image(systemName: "flag.fill")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
        case .gap(let durationMs):
            HStack(spacing: 8) {
                Rectangle().fill(.quaternary).frame(height: 1)
                Text("此处中断 \(SessionTimeline.gapSeconds(durationMs)) 秒")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Rectangle().fill(.quaternary).frame(height: 1)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

private struct ProcessingView: View {
    let manifest: SessionManifest
    let state: SessionDisplayState
    let loadError: String?
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            StateBadge(state: state).scaleEffect(1.3)
            Text(DurationText.clock(ms: manifest.totalDurationMs))
                .font(.system(size: 44, weight: .light, design: .rounded))
                .monospacedDigit()
            if let detail = state.detail { Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            if case .transcribing(let progress, _) = state {
                ProgressView(value: progress).frame(maxWidth: 240)
            }
            if let loadError { Text(loadError).foregroundStyle(.red).font(.footnote) }
            if case .uploading = state {
                Button("立即重试", action: retry).buttonStyle(.bordered)
            }
            Text("\(manifest.sealedSegments.count) 段 · 开始于 \(manifest.startedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Color {
    init?(hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(
            red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
