// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import SwiftUI
import UIKit
import WendaoKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// 系统在后台上传完成后唤醒 App：把完成回调交给后台传输，事件处理完后由它调用。
    func application(
        _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundUploadTransport.defaultIdentifier else {
            completionHandler()
            return
        }
        let box = CompletionBox(completionHandler)
        WendaoApp.sharedModel?.backgroundTransport.setBackgroundEventsCompletion { box.call() }
    }
}

/// 把非 Sendable 的系统回调包起来，只在主线程调用。
private final class CompletionBox: @unchecked Sendable {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    func call() { handler() }
}

@main
struct WendaoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: AppModel

    @MainActor static var sharedModel: AppModel?

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        WendaoApp.sharedModel = model
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.launch() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.becameActive() }
        }
    }
}
