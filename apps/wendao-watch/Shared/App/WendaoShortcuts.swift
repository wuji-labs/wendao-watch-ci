// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import AppIntents

/// 快捷指令与 Siri 短语；在 Apple Watch Ultra 上可把 Action Button 设为「开始闻道录音」。
struct WendaoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "用\(.applicationName)开始录音",
                "\(.applicationName)开始录音",
                "\(.applicationName)录音"
            ],
            shortTitle: "开始录音",
            systemImageName: "mic.fill")
        AppShortcut(
            intent: StopRecordingIntent(),
            phrases: [
                "用\(.applicationName)结束录音",
                "\(.applicationName)结束录音"
            ],
            shortTitle: "结束录音",
            systemImageName: "stop.fill")
    }

    static let shortcutTileColor: ShortcutTileColor = .red
}
