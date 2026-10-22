// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import SwiftUI
import WendaoKit

@main
struct WendaoWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = WatchModel()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(model)
                .task { await model.launch() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.recording.resumeIfInterrupted() }
        }
    }
}

struct WatchRootView: View {
    @Environment(WatchModel.self) private var model
    @State private var markPulse = false

    private var recording: RecordingController { model.recording }

    var body: some View {
        VStack(spacing: 6) {
            header
            Spacer(minLength: 0)
            if recording.isRecording {
                HStack(spacing: 14) {
                    recordButton(size: 70)
                    markButton
                }
            } else {
                // 未在录音：双指互点 = 开始录音
                recordButton(size: 92)
                    .handGestureShortcut(.primaryAction)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, 8)
        .alert(
            "闻道",
            isPresented: Binding(
                get: { recording.alertMessage != nil }, set: { if !$0 { recording.alertMessage = nil } })
        ) {
            Button("好") { recording.alertMessage = nil }
        } message: {
            Text(recording.alertMessage ?? "")
        }
    }

    @ViewBuilder
    private var header: some View {
        if recording.isRecording {
            HStack(spacing: 5) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text(recording.phase == .interrupted ? "已打断·恢复中" : "录音中")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.red)
            }
            .accessibilityElement(children: .combine)
            if let started = recording.sessionStartedAt {
                Text(started, style: .timer)
                    .font(.system(.title2, design: .rounded).weight(.medium))
                    .monospacedDigit()
            }
        } else {
            Text("闻道")
                .font(.headline)
            Text(model.isBound ? "点按开始录音" : "请先在 iPhone 上完成绑定")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func recordButton(size: CGFloat) -> some View {
        Button {
            if recording.isRecording {
                recording.stop()
            } else {
                Task { await recording.start() }
            }
        } label: {
            ZStack {
                Circle()
                    .stroke(.red.opacity(0.35), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: CGFloat(max(0.02, recording.level)))
                    .stroke(.red, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .opacity(recording.isRecording ? 1 : 0)
                    .animation(.linear(duration: 0.2), value: recording.level)
                if recording.isRecording {
                    RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: size * 0.32, height: size * 0.32)
                } else {
                    Circle().fill(.red).padding(10)
                    Image(systemName: "mic.fill").font(.title2).foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .disabled(recording.phase == .starting || recording.phase == .stopping)
        .accessibilityLabel(recording.isRecording ? "结束录音" : "开始录音")
    }

    /// 「标记」：点按记 tap；录音中双指互点（手势快捷方式触发按钮动作）记 doubleTap。
    /// 点按由高优先级点击手势接走，按钮动作只剩手势快捷方式一条来路，两种来源因此分得开。
    private var markButton: some View {
        Button {
            recording.mark(.doubleTap)
        } label: {
            ZStack(alignment: .topTrailing) {
                Circle()
                    .fill(.orange.opacity(0.22))
                    .overlay(Image(systemName: "flag.fill").font(.title3).foregroundStyle(.orange))
                    .frame(width: 54, height: 54)
                    .scaleEffect(markPulse ? 1.18 : 1)
                    .animation(.spring(response: 0.25, dampingFraction: 0.5), value: markPulse)
                if recording.markCount > 0 {
                    Text("\(recording.markCount)")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .background(.orange, in: Capsule())
                        .foregroundStyle(.black)
                        .offset(x: 4, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
        .highPriorityGesture(TapGesture().onEnded { recording.mark(.tap) })
        .handGestureShortcut(.primaryAction)
        .accessibilityLabel("标记此刻")
        .accessibilityValue(recording.markCount > 0 ? "已标记 \(recording.markCount) 处" : "")
        .onChange(of: recording.lastMarkAt) { _, at in
            guard at != nil else { return }
            markPulse = true
            Task {
                try? await Task.sleep(for: .milliseconds(180))
                markPulse = false
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if recording.isRecording {
            Text("已保存 \(recording.segmentCount) 段")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if model.pendingSegments > 0 {
            Label(
                model.phoneReachable ? "正在同步 \(model.pendingSegments) 段" :
                    (model.networkAvailable ? "正在上传 \(model.pendingSegments) 段" : "待同步 \(model.pendingSegments) 段"),
                systemImage: "arrow.up.circle"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else {
            Label("已全部同步", systemImage: "checkmark.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
