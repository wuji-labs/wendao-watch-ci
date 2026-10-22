// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import SwiftUI
import WendaoKit

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if !model.consentAccepted {
                ConsentView()
            } else if !model.isBound {
                NavigationStack { BindView() }
            } else {
                SessionListView()
            }
        }
        .tint(.red)
    }
}

/// 首次使用：录音告知与同意。
struct ConsentView: View {
    @Environment(AppModel.self) private var model
    @State private var agreed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.red)
                    Text("闻道")
                        .font(.largeTitle.bold())
                    Text("抬腕即录，云端转写，自动生成纪要。")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 16) {
                    ConsentItem(
                        icon: "person.2.wave.2", title: "录音前请告知在场的人",
                        text: "录制他人谈话须取得在场者知情。录音期间手表与手机会一直显示录音标识。")
                    ConsentItem(
                        icon: "lock.shield", title: "录音只属于您",
                        text: "原始录音、转写文字与纪要保存在您本人的闻道账号中，用于转写与生成纪要，不用于其他用途。")
                    ConsentItem(
                        icon: "sparkles", title: "转写与纪要由 AI 生成",
                        text: "文字稿、说话人区分、摘要与待办由人工智能自动生成，可能存在误差，请以原始录音为准。")
                    ConsentItem(
                        icon: "externaldrive.badge.checkmark", title: "分段保存，断网不丢",
                        text: "录音每 5 分钟保存一段，来电或闹钟打断后自动续录；网络恢复后自动补传。")
                }

                Toggle(isOn: $agreed) {
                    Text("我已了解并同意以上说明")
                        .font(.callout)
                }
                .toggleStyle(.switch)

                Button {
                    model.consentAccepted = true
                } label: {
                    Text("同意并继续")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!agreed)
            }
            .padding(24)
        }
    }
}

private struct ConsentItem: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.red)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

/// 手机号 + 验证码绑定本设备。
struct BindView: View {
    @Environment(AppModel.self) private var model
    @State private var phone = ""
    @State private var code = ""
    @State private var countdown = 0
    @State private var busy = false
    @State private var message: String?
    @State private var countdownTask: Task<Void, Never>?

    private var phoneValid: Bool {
        phone.count == 11 && phone.hasPrefix("1") && phone.allSatisfy(\.isASCIIDigit)
    }

    var body: some View {
        Form {
            Section {
                TextField("手机号", text: $phone)
                    .keyboardType(.numberPad)
                    .textContentType(.telephoneNumber)
                HStack {
                    TextField("6 位验证码", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                    Button(countdown > 0 ? "\(countdown) 秒后重发" : "获取验证码") {
                        Task { await sendCode() }
                    }
                    .disabled(!phoneValid || countdown > 0 || busy)
                }
            } footer: {
                Text("使用闻道账号的手机号；未注册的手机号将自动创建账号。绑定后，手表与本机的录音都会进入这个账号。")
            }

            Section {
                Button {
                    Task { await bind() }
                } label: {
                    HStack {
                        Spacer()
                        if busy { ProgressView() } else { Text("绑定").font(.headline) }
                        Spacer()
                    }
                }
                .disabled(!phoneValid || code.count != 6 || busy)
            }

            if let message {
                Section { Text(message).foregroundStyle(.red) }
            }
        }
        .navigationTitle(model.needsRebind ? "重新绑定" : "绑定闻道账号")
        .onDisappear { countdownTask?.cancel() }
    }

    private func sendCode() async {
        busy = true
        message = nil
        defer { busy = false }
        do {
            let out = try await model.sendCode(phone: phone)
            startCountdown(out.retryAfterSec)
            if let dev = out.devCode { code = dev }
        } catch let e as WendaoAPIError {
            message = e.userMessage
        } catch {
            message = error.localizedDescription
        }
    }

    private func bind() async {
        busy = true
        message = nil
        defer { busy = false }
        do {
            try await model.bind(phone: phone, code: code)
        } catch let e as WendaoAPIError {
            message = e.userMessage
        } catch {
            message = "保存登录状态失败：\(error.localizedDescription)"
        }
    }

    private func startCountdown(_ seconds: Int) {
        countdownTask?.cancel()
        countdown = max(seconds, 1)
        countdownTask = Task {
            while countdown > 0, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                countdown -= 1
            }
        }
    }
}

extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
