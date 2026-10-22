// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import SwiftUI
import WendaoKit

/// 在 iPhone 上直接录音（与手表同一条分段与上传管线）。
struct PhoneRecorderView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""

    private var recording: RecordingController { model.recording }

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()
                if recording.isRecording {
                    HStack(spacing: 8) {
                        Circle().fill(.red).frame(width: 10, height: 10)
                        Text(recording.phase == .interrupted ? "已被打断，正在恢复…" : "正在录音")
                            .font(.headline)
                    }
                    if let started = recording.sessionStartedAt {
                        Text(started, style: .timer)
                            .font(.system(size: 64, weight: .light, design: .rounded))
                            .monospacedDigit()
                    }
                    LevelMeter(level: recording.level)
                        .frame(height: 8)
                        .padding(.horizontal, 48)
                    Text("已保存 \(recording.segmentCount) 段").font(.footnote).foregroundStyle(.secondary)
                } else {
                    TextField("标题（可不填）", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal, 32)
                    Text("录音每 5 分钟自动保存一段，结束后自动上传转写。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                Spacer()
                Button {
                    if recording.isRecording {
                        recording.stop()
                    } else {
                        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { await recording.start(title: t.isEmpty ? nil : t) }
                    }
                } label: {
                    ZStack {
                        Circle().strokeBorder(.secondary.opacity(0.4), lineWidth: 4).frame(width: 96, height: 96)
                        if recording.isRecording {
                            RoundedRectangle(cornerRadius: 8).fill(.red).frame(width: 36, height: 36)
                        } else {
                            Circle().fill(.red).frame(width: 78, height: 78)
                        }
                    }
                }
                .accessibilityLabel(recording.isRecording ? "结束录音" : "开始录音")
                .disabled(recording.phase == .starting || recording.phase == .stopping)
                .padding(.bottom, 40)
            }
            .navigationTitle("手机录音")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
            }
            .alert(
                "提示",
                isPresented: Binding(
                    get: { recording.alertMessage != nil }, set: { if !$0 { recording.alertMessage = nil } })
            ) {
                Button("好") { recording.alertMessage = nil }
            } message: {
                Text(recording.alertMessage ?? "")
            }
        }
    }
}

struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.red)
                    .frame(width: max(4, geo.size.width * CGFloat(level)))
                    .animation(.linear(duration: 0.2), value: level)
            }
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var serverText = ""
    @State private var serverError: String?
    @State private var confirmUnbind = false

    var body: some View {
        NavigationStack {
            Form {
                Section("账号") {
                    LabeledContent("状态", value: model.isBound ? "已绑定" : "未绑定")
                    if model.isBound {
                        Button("解除绑定", role: .destructive) { confirmUnbind = true }
                    }
                }
                Section {
                    TextField("服务器地址", text: $serverText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("保存") {
                        Task { await saveServer() }
                    }
                    Button("恢复默认") {
                        serverText = WendaoServer.production.absoluteString
                        Task { await saveServer() }
                    }
                    if let serverError { Text(serverError).foregroundStyle(.red) }
                } header: {
                    Text("服务器")
                } footer: {
                    Text("默认连接闻道官方服务。仅在调试或私有部署时修改，例如局域网地址。")
                }
                Section("关于") {
                    LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                    Text("录音由闻道云端转写并生成纪要，内容由人工智能生成。录音原件保存在您本人的闻道账号中。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
            .onAppear { serverText = model.baseURL.absoluteString }
            .confirmationDialog("解除绑定后，手表与本机将停止上传，直到重新绑定。", isPresented: $confirmUnbind, titleVisibility: .visible) {
                Button("解除绑定", role: .destructive) {
                    model.unbind()
                    dismiss()
                }
            }
        }
    }

    private func saveServer() async {
        guard let url = WendaoServer.normalizedBaseURL(serverText) else {
            serverError = "地址无效，请填写以 http:// 或 https:// 开头的地址"
            return
        }
        serverError = nil
        await model.updateBaseURL(url)
        serverText = url.absoluteString
    }
}
