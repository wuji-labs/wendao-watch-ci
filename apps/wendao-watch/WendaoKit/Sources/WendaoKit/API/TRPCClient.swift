// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// 接口错误。以 tRPC 错误码为准，取不到再看 HTTP 状态码。
public enum WendaoAPIError: Error, Sendable, Equatable {
    /// 401：未绑定或令牌失效。
    case unauthorized
    case forbidden(String)
    /// 404：会话不存在或不属于当前用户。
    case notFound(String)
    /// 409：同一序号已收到内容不同的分段（finalize 时也表示「正在合成」）。
    case conflict(String)
    /// 409 `session closed`：会话已终结或正在合成，不再接收分段。
    case sessionClosed(String)
    /// 412：终结时缺段。
    case preconditionFailed(String)
    case tooManyRequests(String)
    case badRequest(String)
    case server(status: Int, message: String)
    case transport(String)
    case decoding(String)

    /// 可退避重试的错误。
    public var isRetryable: Bool {
        switch self {
        case .transport, .tooManyRequests: return true
        case .server(let status, _): return status >= 500 || status == 408
        case .decoding: return true
        default: return false
        }
    }

    /// 面向用户的中文说明。
    public var userMessage: String {
        switch self {
        case .unauthorized: return "设备未绑定或绑定已失效，请重新绑定"
        case .forbidden(let m): return m.isEmpty ? "无权访问" : m
        case .notFound(let m): return m.isEmpty ? "内容不存在" : m
        case .conflict: return "分段内容与已上传版本不一致"
        case .sessionClosed: return "录音已在服务端合成"
        case .preconditionFailed(let m): return m.isEmpty ? "分段尚未收齐" : m
        case .tooManyRequests(let m): return m.isEmpty ? "操作太频繁，请稍后再试" : m
        case .badRequest(let m): return m.isEmpty ? "请求有误" : m
        case .server(let status, let m): return m.isEmpty ? "服务暂不可用（\(status)）" : m
        case .transport: return "网络不可用，稍后自动重试"
        case .decoding: return "服务返回了无法识别的数据"
        }
    }

    static func from(trpcCode: String?, httpStatus: Int, message: String) -> WendaoAPIError {
        switch trpcCode {
        case "UNAUTHORIZED": return .unauthorized
        case "FORBIDDEN": return .forbidden(message)
        case "NOT_FOUND": return .notFound(message)
        case "CONFLICT": return .conflict(message)
        case "PRECONDITION_FAILED": return .preconditionFailed(message)
        case "TOO_MANY_REQUESTS": return .tooManyRequests(message)
        case "BAD_REQUEST", "PARSE_ERROR", "PAYLOAD_TOO_LARGE", "UNPROCESSABLE_CONTENT":
            return .badRequest(message)
        default: break
        }
        switch httpStatus {
        case 401: return .unauthorized
        case 403: return .forbidden(message)
        case 404: return .notFound(message)
        case 409: return .conflict(message)
        case 412: return .preconditionFailed(message)
        case 429: return .tooManyRequests(message)
        case 400, 413, 415, 422: return .badRequest(message)
        default: return .server(status: httpStatus, message: message)
        }
    }
}

/// tRPC v11 HTTP 协议（服务端未配置 transformer，载荷是普通 JSON）：
///
/// - query：`GET /trpc/<path>?input=<URL 编码的 JSON>`
/// - mutation：`POST /trpc/<path>`，请求体即 input 的 JSON
/// - 成功：`{"result":{"data":<output>}}`
/// - 失败：`{"error":{"message":"…","code":-32001,"data":{"code":"UNAUTHORIZED","httpStatus":401,…}}}`
struct TRPCClient: Sendable {
    let baseURL: URL
    let transport: any HTTPTransport
    let headers: @Sendable () async -> [String: String]

    private struct ResultEnvelope<T: Decodable>: Decodable {
        struct Inner: Decodable { let data: T }
        let result: Inner
    }

    struct ErrorEnvelope: Decodable {
        struct Shape: Decodable {
            struct DataShape: Decodable {
                let code: String?
                let httpStatus: Int?
            }
            let message: String?
            let data: DataShape?
        }
        let error: Shape
    }

    func endpoint(_ path: String) -> URL {
        baseURL.appendingPathComponent("trpc").appendingPathComponent(path)
    }

    func query<Input: Encodable & Sendable, Output: Decodable>(
        _ path: String, input: Input
    ) async throws -> Output {
        let json = try WendaoJSON.encoder().encode(input)
        guard var components = URLComponents(url: endpoint(path), resolvingAgainstBaseURL: false) else {
            throw WendaoAPIError.badRequest("无效的接口地址")
        }
        components.percentEncodedQuery = "input=" + Self.percentEncode(String(decoding: json, as: UTF8.self))
        guard let url = components.url else { throw WendaoAPIError.badRequest("无效的接口地址") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        return try await send(request)
    }

    func mutation<Input: Encodable & Sendable, Output: Decodable>(
        _ path: String, input: Input
    ) async throws -> Output {
        var request = URLRequest(url: endpoint(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try WendaoJSON.encoder().encode(input)
        return try await send(request)
    }

    private func send<Output: Decodable>(_ base: URLRequest) async throws -> Output {
        var request = base
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in await headers() { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await transport.data(for: request)
        } catch let e as WendaoAPIError {
            throw e
        } catch {
            throw WendaoAPIError.transport(error.localizedDescription)
        }
        return try Self.decode(data: data, response: response)
    }

    static func decode<Output: Decodable>(data: Data, response: HTTPURLResponse) throws -> Output {
        let decoder = WendaoJSON.decoder()
        if (200..<300).contains(response.statusCode) {
            do {
                return try decoder.decode(ResultEnvelope<Output>.self, from: data).result.data
            } catch {
                throw WendaoAPIError.decoding(String(describing: error))
            }
        }
        throw apiError(data: data, status: response.statusCode)
    }

    static func apiError(data: Data, status: Int) -> WendaoAPIError {
        if let env = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
            return .from(
                trpcCode: env.error.data?.code, httpStatus: env.error.data?.httpStatus ?? status,
                message: env.error.message ?? "")
        }
        // 非 tRPC 端点（/upload/segment）返回 {"error":"…","message":"…"} 或纯文本
        struct Plain: Decodable {
            let error: String?
            let message: String?
        }
        let plain = try? JSONDecoder().decode(Plain.self, from: data)
        if status == 409, plain?.error == "session closed" {
            return .sessionClosed(plain?.message ?? "")
        }
        let message = plain?.error ?? String(decoding: data.prefix(200), as: UTF8.self)
        return .from(trpcCode: nil, httpStatus: status, message: message)
    }

    /// 严格的 URL 查询编码：只保留 RFC 3986 非保留字符。`+` 必须编码，否则服务端会解析成空格。
    static func percentEncode(_ s: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
