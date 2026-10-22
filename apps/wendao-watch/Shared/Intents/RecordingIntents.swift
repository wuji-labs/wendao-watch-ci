// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import AppIntents
import WendaoKit

/// 开始录音。供 Action Button、控制中心、Smart Stack 小组件与快捷指令使用。
///
/// 录音必须由前台 App 启动音频会话，所以运行时拉起 App；指令经 `RecordingCommandCenter` 交给录音控制器。
struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "开始闻道录音"
    static let description = IntentDescription("立即开始录音。录音分段保存，并上传到您本人的闻道账号转写。")
    static let openAppWhenRun: Bool = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await RecordingCommandCenter.shared.submit(.start)
        return .result()
    }
}

/// 结束录音并保存。
struct StopRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "结束闻道录音"
    static let description = IntentDescription("结束当前录音并保存，随后自动上传转写。")
    static let openAppWhenRun: Bool = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await RecordingCommandCenter.shared.submit(.stop)
        return .result()
    }
}

/// 开始或结束录音（一个按钮切换）。
struct ToggleRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "闻道录音开关"
    static let description = IntentDescription("未在录音时开始录音，正在录音时结束并保存。")
    static let openAppWhenRun: Bool = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await RecordingCommandCenter.shared.submit(.toggle)
        return .result()
    }
}
