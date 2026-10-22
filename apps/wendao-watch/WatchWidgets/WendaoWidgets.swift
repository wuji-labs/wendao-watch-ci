// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import AppIntents
import SwiftUI
import WendaoKit
import WidgetKit

struct RecordEntry: TimelineEntry {
    let date: Date
    let status: RecordingStatusSnapshot
}

struct RecordProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecordEntry {
        RecordEntry(date: Date(), status: .idle)
    }

    func getSnapshot(in context: Context, completion: @escaping (RecordEntry) -> Void) {
        completion(RecordEntry(date: Date(), status: RecordingStatusSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecordEntry>) -> Void) {
        let entry = RecordEntry(date: Date(), status: RecordingStatusSnapshot.load())
        // 状态变化时 App 会主动刷新；这里只做兜底刷新
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

struct RecordWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RecordEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            circular
        case .accessoryInline:
            inline
        default:
            rectangular
        }
    }

    private var isRecording: Bool { entry.status.isRecording }

    @ViewBuilder
    private var actionButton: some View {
        if isRecording {
            Button(intent: StopRecordingIntent()) {
                Image(systemName: "stop.fill").font(.title3)
            }
            .tint(.red)
        } else {
            Button(intent: StartRecordingIntent()) {
                Image(systemName: "mic.fill").font(.title3)
            }
            .tint(.red)
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                .font(.title3)
                .widgetAccentable()
        }
    }

    private var inline: some View {
        Label(isRecording ? "闻道 录音中" : "闻道 点按录音", systemImage: isRecording ? "record.circle" : "mic")
    }

    private var rectangular: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if isRecording { Circle().fill(.red).frame(width: 6, height: 6) }
                    Text("闻道").font(.headline).widgetAccentable()
                }
                if isRecording, let started = entry.status.startedAt {
                    Text(started, style: .timer).font(.caption).monospacedDigit()
                } else if entry.status.pendingSegments > 0 {
                    Text("待同步 \(entry.status.pendingSegments) 段").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("一键录音").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            actionButton
        }
    }
}

struct RecordWidget: Widget {
    let kind = "com.wujilabs.wendao.record"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RecordProvider()) { entry in
            RecordWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("闻道录音")
        .description("一键开始或结束录音。")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

#if compiler(>=6.2)
    /// 控制中心按钮（watchOS 26 起）。
    @available(watchOS 26.0, *)
    struct RecordControl: ControlWidget {
        var body: some ControlWidgetConfiguration {
            StaticControlConfiguration(kind: "com.wujilabs.wendao.record-control") {
                ControlWidgetButton(action: ToggleRecordingIntent()) {
                    Label("闻道录音", systemImage: "mic.fill")
                }
            }
            .displayName("闻道录音")
            .description("开始或结束录音。")
        }
    }
#endif

@main
struct WendaoWidgets: WidgetBundle {
    var body: some Widget {
        RecordWidget()
        #if compiler(>=6.2)
            if #available(watchOS 26.0, *) {
                RecordControl()
            }
        #endif
    }
}
