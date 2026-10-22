// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// 上传队列依赖的服务端能力（W1 录音会话协议）。测试用桩实现。
public protocol RecordingBackend: Sendable {
    func beginRecording(_ input: RecordingBeginInput) async throws -> RecordingBeginOutput
    func recordingStatus(sessionId: String) async throws -> RecordingStatusOutput
    func uploadSegment(_ upload: SegmentUpload) async throws
    func finalizeRecording(_ input: RecordingFinalizeInput) async throws -> RecordingFinalizeOutput
}

/// 服务端地址配置。
public struct WendaoServer: Sendable, Equatable {
    public static let production = URL(string: "https://wendao.chengqiyun.com")!

    /// 校验用户在调试设置里填的地址：只接受 http/https 且有主机名，去掉末尾斜杠。
    public static func normalizedBaseURL(_ text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
            scheme == "https" || scheme == "http", let host = url.host, !host.isEmpty,
            url.query == nil, url.fragment == nil
        else { return nil }
        return url
    }
}

/// 闻道接口客户端：设备绑定、`X-Device-Token` 注入、tRPC 调用、分段上传、妙记查询。
public struct WendaoAPI: RecordingBackend {
    public static let deviceTokenHeader = "X-Device-Token"

    public let baseURL: URL
    private let transport: any HTTPTransport
    private let uploadTransport: any HTTPTransport
    private let tokenProvider: @Sendable () async -> String?
    private let scratchDirectory: URL
    private let trpc: TRPCClient

    /// - Parameters:
    ///   - transport: 普通请求。
    ///   - uploadTransport: 分段上传（iPhone 传 `BackgroundUploadTransport`）；缺省同 `transport`。
    ///   - tokenProvider: 每次请求时读取设备令牌（来自钥匙串）。
    ///   - scratchDirectory: multipart 临时请求体存放处。
    public init(
        baseURL: URL = WendaoServer.production,
        transport: any HTTPTransport = URLSessionTransport(),
        uploadTransport: (any HTTPTransport)? = nil,
        scratchDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "wendao-upload", isDirectory: true),
        tokenProvider: @escaping @Sendable () async -> String?
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.uploadTransport = uploadTransport ?? transport
        self.tokenProvider = tokenProvider
        self.scratchDirectory = scratchDirectory
        self.trpc = TRPCClient(baseURL: baseURL, transport: transport) {
            guard let token = await tokenProvider(), !token.isEmpty else { return [:] }
            return [WendaoAPI.deviceTokenHeader: token]
        }
    }

    // MARK: 设备绑定

    public func sendDeviceBindCode(phone: String) async throws -> SendCodeOutput {
        try await trpc.mutation("auth.sendDeviceBindCode", input: SendDeviceBindCodeInput(phone: phone))
    }

    public func bindDevice(phone: String, code: String, deviceName: String) async throws -> BindDeviceOutput {
        try await trpc.mutation(
            "auth.bindDeviceWithCode",
            input: BindDeviceWithCodeInput(phone: phone, code: code, deviceName: deviceName))
    }

    // MARK: 妙记

    public func minuteStatus(id: String) async throws -> MinuteStatus {
        try await trpc.query("minute.status", input: MinuteIdInput(id: id))
    }

    public func minuteDetail(token: String) async throws -> MinuteDetail {
        try await trpc.query("minute.getByToken", input: MinuteTokenInput(token: token))
    }

    // MARK: 录音会话（W1）

    public func beginRecording(_ input: RecordingBeginInput) async throws -> RecordingBeginOutput {
        try await trpc.mutation("recording.begin", input: input)
    }

    public func recordingStatus(sessionId: String) async throws -> RecordingStatusOutput {
        try await trpc.query("recording.status", input: RecordingSessionRef(sessionId: sessionId))
    }

    public func finalizeRecording(_ input: RecordingFinalizeInput) async throws -> RecordingFinalizeOutput {
        try await trpc.mutation("recording.finalize", input: input)
    }

    public func uploadSegment(_ upload: SegmentUpload) async throws {
        var body = MultipartBody()
        body.addField("sessionId", upload.sessionId)
        body.addField("seq", String(upload.seq))
        body.addField("sha256", upload.sha256)
        let bodyFile = scratchDirectory.appendingPathComponent(UUID().uuidString + ".multipart")
        do {
            try body.write(
                fileField: "file", fileURL: upload.fileURL, fileName: upload.fileName,
                mimeType: Self.mimeType(for: upload.fileName), to: bodyFile)
        } catch {
            throw WendaoAPIError.transport("无法读取分段文件：\(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: bodyFile) }

        var request = URLRequest(url: baseURL.appendingPathComponent("upload").appendingPathComponent("segment"))
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = await tokenProvider(), !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: Self.deviceTokenHeader)
        }
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await uploadTransport.upload(for: request, fromFile: bodyFile)
        } catch let e as WendaoAPIError {
            throw e
        } catch {
            throw WendaoAPIError.transport(error.localizedDescription)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw TRPCClient.apiError(data: data, status: response.statusCode)
        }
    }

    static func mimeType(for fileName: String) -> String {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "m4a", "mp4": return "audio/mp4"
        case "aac": return "audio/aac"
        case "caf": return "audio/x-caf"
        case "wav": return "audio/wav"
        default: return "application/octet-stream"
        }
    }

    /// 网页查看地址（分享与「在浏览器打开」用）。
    public func webURL(minuteToken: String) -> URL {
        baseURL.appendingPathComponent("m").appendingPathComponent(minuteToken)
    }
}
