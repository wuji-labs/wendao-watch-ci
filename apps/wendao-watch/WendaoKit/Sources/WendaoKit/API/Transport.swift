// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// HTTP 传输抽象：前台走 `URLSession`，iPhone 后台上传走 `BackgroundUploadTransport`，测试走 `URLProtocol` 桩。
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        return (data, try Self.http(response))
    }

    public func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.upload(for: request, fromFile: fileURL)
        return (data, try Self.http(response))
    }

    static func http(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw WendaoAPIError.transport("非 HTTP 响应")
        }
        return http
    }
}

#if canImport(Darwin)
/// iPhone 后台上传：系统在 App 挂起后继续传，完成后唤醒 App。
///
/// 进程存活时以 continuation 把结果交回调用方；进程被杀重启后，旧任务的结果不再有人等，
/// 由 `UploadQueue` 下一轮先查 `recording.status` 对账——服务端已收就不再重传，所以不会丢也不会重复。
public final class BackgroundUploadTransport: NSObject, HTTPTransport, URLSessionDataDelegate, @unchecked Sendable {
    public static let defaultIdentifier = "com.wujilabs.wendao.background-upload"

    private struct Pending {
        var continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>
        var body: Data
        var bodyFile: URL
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var finishEventsHandler: (@Sendable () -> Void)?
    private let foreground: URLSessionTransport
    private var backgroundSession: URLSession?

    public init(identifier: String = BackgroundUploadTransport.defaultIdentifier) {
        self.foreground = URLSessionTransport()
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        backgroundSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// 由 `application(_:handleEventsForBackgroundURLSession:completionHandler:)` 交入。
    public func setBackgroundEventsCompletion(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { finishEventsHandler = handler }
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await foreground.data(for: request)
    }

    public func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, HTTPURLResponse) {
        guard let session = backgroundSession else { throw WendaoAPIError.transport("后台会话未就绪") }
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.uploadTask(with: request, fromFile: fileURL)
            lock.withLock {
                pending[task.taskIdentifier] = Pending(continuation: continuation, body: Data(), bodyFile: fileURL)
            }
            task.resume()
        }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { pending[dataTask.taskIdentifier]?.body.append(data) }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let entry = lock.withLock { pending.removeValue(forKey: task.taskIdentifier) }
        guard let entry else { return }
        if let error {
            entry.continuation.resume(throwing: WendaoAPIError.transport(error.localizedDescription))
        } else if let http = task.response as? HTTPURLResponse {
            entry.continuation.resume(returning: (entry.body, http))
        } else {
            entry.continuation.resume(throwing: WendaoAPIError.transport("上传未返回响应"))
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = lock.withLock { () -> (@Sendable () -> Void)? in
            let h = finishEventsHandler
            finishEventsHandler = nil
            return h
        }
        if let handler {
            DispatchQueue.main.async { handler() }
        }
    }
}
#endif
