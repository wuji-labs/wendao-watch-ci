// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import XCTest

@testable import WendaoKit

/// `URLProtocol` 桩：拦截全部请求，按测试设定的处理器返回。测试绝不触达真实服务。
final class StubURLProtocol: URLProtocol {
    struct Captured: Sendable {
        var request: URLRequest
        var body: Data?
    }

    typealias Handler = @Sendable (URLRequest) -> (Int, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var captured: [Captured] = []

    static func install(_ h: @escaping Handler) {
        lock.withLock {
            handler = h
            captured = []
        }
    }

    static var requests: [Captured] { lock.withLock { captured } }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let req = request
        let body = req.httpBody ?? Self.drain(req.httpBodyStream)
        let h = Self.lock.withLock { () -> Handler? in
            Self.captured.append(Captured(request: req, body: body))
            return Self.handler
        }
        let (status, data) = h?(req) ?? (500, Data())
        let response = HTTPURLResponse(
            url: req.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

private func json(_ s: String) -> Data { Data(s.utf8) }

final class WendaoAPITests: XCTestCase {
    private let base = URL(string: "https://wendao.example.test")!

    private func makeAPI(token: String? = "dev-token-123") -> WendaoAPI {
        let store = InMemoryTokenStore(token: token)
        return WendaoAPI(
            baseURL: base, transport: URLSessionTransport(session: StubURLProtocol.session()),
            scratchDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(
                "wendao-api-tests-\(UUID().uuidString)"),
            tokenProvider: { try? store.readToken() })
    }

    func testQueryEncodesInputAndInjectsDeviceToken() async throws {
        StubURLProtocol.install { _ in
            (
                200,
                json(
                    #"{"result":{"data":{"id":"6f1c2a4e-0000-4000-8000-000000000001","status":"TRANSCRIBING","errorMessage":null,"durationMs":61000,"title":"周会","jobs":[{"id":"j1","minuteId":"m","stage":"ASR","status":"RUNNING","progress":0.5,"errorMessage":null,"startedAt":"2026-10-21T08:00:00.000Z","finishedAt":null,"createdAt":"2026-10-21T08:00:00.000Z"},{"id":"j2","stage":"TRANSCODE","status":"DONE","progress":1}]}}}"#
                )
            )
        }
        let status = try await makeAPI().minuteStatus(id: "6f1c2a4e-0000-4000-8000-000000000001")
        XCTAssertEqual(status.status, .transcribing)
        XCTAssertEqual(status.durationMs, 61000)
        XCTAssertEqual(status.jobs.count, 2)
        XCTAssertEqual(status.overallProgress, 0.75, accuracy: 1e-9)

        let req = try XCTUnwrap(StubURLProtocol.requests.first).request
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.url?.path, "/trpc/minute.status")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Device-Token"), "dev-token-123")
        let query = try XCTUnwrap(req.url?.query)
        XCTAssertEqual(query, "input=%7B%22id%22%3A%226f1c2a4e-0000-4000-8000-000000000001%22%7D")
    }

    func testQueryPercentEncodesPlusAndUnicode() {
        XCTAssertEqual(TRPCClient.percentEncode(#"{"a":"1+2 闻"}"#), "%7B%22a%22%3A%221%2B2%20%E9%97%BB%22%7D")
    }

    func testMutationPostsJSONBody() async throws {
        StubURLProtocol.install { _ in (200, json(#"{"result":{"data":{"ok":true,"retryAfterSec":60}}}"#)) }
        let out = try await makeAPI(token: nil).sendDeviceBindCode(phone: "13800138000")
        XCTAssertTrue(out.ok)
        XCTAssertNil(out.devCode)
        XCTAssertEqual(out.retryAfterSec, 60)

        let captured = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(captured.request.httpMethod, "POST")
        XCTAssertEqual(captured.request.url?.path, "/trpc/auth.sendDeviceBindCode")
        XCTAssertEqual(captured.request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(captured.request.value(forHTTPHeaderField: "X-Device-Token"), "未绑定时不带令牌")
        let body = try XCTUnwrap(captured.body)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: String], ["phone": "13800138000"])
    }

    func testBindDeviceDecodesToken() async throws {
        StubURLProtocol.install { _ in
            (
                200,
                json(
                    #"{"result":{"data":{"deviceToken":"dt_abc","userId":"6f1c2a4e-0000-4000-8000-000000000002","deviceName":"Apple Watch"}}}"#
                )
            )
        }
        let out = try await makeAPI(token: nil).bindDevice(phone: "13800138000", code: "123456", deviceName: "Apple Watch")
        XCTAssertEqual(out.deviceToken, "dt_abc")
        let body = try XCTUnwrap(StubURLProtocol.requests.first?.body)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(obj, ["phone": "13800138000", "code": "123456", "deviceName": "Apple Watch"])
    }

    func testTRPCErrorsMapToTypedErrors() async throws {
        let cases: [(Int, String, WendaoAPIError)] = [
            (401, "UNAUTHORIZED", .unauthorized),
            (404, "NOT_FOUND", .notFound("x")),
            (412, "PRECONDITION_FAILED", .preconditionFailed("x")),
            (429, "TOO_MANY_REQUESTS", .tooManyRequests("x")),
            (409, "CONFLICT", .conflict("x")),
            (500, "INTERNAL_SERVER_ERROR", .server(status: 500, message: "x"))
        ]
        for (status, code, expected) in cases {
            StubURLProtocol.install { _ in
                (
                    status,
                    json(
                        #"{"error":{"message":"x","code":-32000,"data":{"code":"\#(code)","httpStatus":\#(status),"path":"minute.status"}}}"#
                    )
                )
            }
            do {
                _ = try await makeAPI().minuteStatus(id: "a")
                XCTFail("应抛错 \(code)")
            } catch let e as WendaoAPIError {
                XCTAssertEqual(e, expected)
            }
        }
        XCTAssertFalse(WendaoAPIError.unauthorized.isRetryable)
        XCTAssertFalse(WendaoAPIError.conflict("").isRetryable)
        XCTAssertTrue(WendaoAPIError.server(status: 502, message: "").isRetryable)
        XCTAssertTrue(WendaoAPIError.tooManyRequests("").isRetryable)
    }

    func testGetByTokenDecodesDetailAndMergesSpeakerTurns() async throws {
        let payload = #"""
            {"result":{"data":{
              "minute":{"id":"m1","token":"tk","ownerId":"u","title":"产品评审","status":"READY","durationMs":125000,"errorMessage":null,"createdAt":"2026-10-21T08:00:00.123Z","source":"MOBILE_RECORD"},
              "role":"OWNER",
              "speakers":[{"id":"s1","minuteId":"m1","displayName":"说话人 1","orderIndex":0,"colorHex":"#3366ff","speakingRatio":0.6,"embedding":null},
                          {"id":"s2","minuteId":"m1","displayName":"说话人 2","orderIndex":1,"colorHex":null,"speakingRatio":0.4}],
              "segments":[{"id":"g1","speakerId":"s1","startMs":0,"endMs":1000,"text":"大家好，","words":[],"orderIndex":0},
                          {"id":"g2","speakerId":"s1","startMs":1000,"endMs":2000,"text":"开始吧。","words":[],"orderIndex":1},
                          {"id":"g3","speakerId":"s2","startMs":2000,"endMs":3000,"text":"好的。","words":[],"orderIndex":2},
                          {"id":"g4","speakerId":null,"startMs":3000,"endMs":3500,"text":"  ","words":[],"orderIndex":3}],
              "summary":{"id":"x","minuteId":"m1","overview":"评审新版首页","keyPoints":[{"text":"首屏加载要快","sourceSegmentId":"g1"}],"risks":[],"status":"DONE","createdAt":"2026-10-21T08:10:00.000Z"},
              "chapters":[{"id":"c1","minuteId":"m1","title":"开场","startMs":0,"endMs":2000,"summary":"寒暄","status":"DONE","orderIndex":0}],
              "todos":[{"id":"t1","minuteId":"m1","text":"周五前出稿","owner":"说话人 2","sourceSegmentId":null,"status":"OPEN","aiStatus":"DONE","externalTaskId":null,"orderIndex":0}],
              "highlights":[],"comments":[],"clips":[],"jobs":[]
            }}}
            """#
        StubURLProtocol.install { _ in (200, json(payload)) }
        let d = try await makeAPI().minuteDetail(token: "tk")
        XCTAssertEqual(d.minute.status, .ready)
        XCTAssertEqual(d.minute.createdAt, WendaoDate.date(from: "2026-10-21T08:00:00.123Z"))
        XCTAssertEqual(d.summary?.keyPoints.first?.text, "首屏加载要快")
        XCTAssertEqual(d.chapters.first?.title, "开场")
        XCTAssertEqual(d.todos.first?.owner, "说话人 2")
        let turns = d.speakerTurns
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].text, "大家好，开始吧。")
        XCTAssertEqual(turns[0].endMs, 2000)
        XCTAssertEqual(turns[0].speaker?.displayName, "说话人 1")
        XCTAssertEqual(turns[1].speaker?.id, "s2")

        let query = try XCTUnwrap(StubURLProtocol.requests.first?.request.url?.query)
        XCTAssertEqual(query, "input=%7B%22token%22%3A%22tk%22%7D")
    }

    func testDecodesNullSummaryAndUnknownStatus() async throws {
        StubURLProtocol.install { _ in
            (
                200,
                json(
                    #"{"result":{"data":{"minute":{"id":"m","token":"t","title":"","status":"SOMETHING_NEW","durationMs":0},"speakers":[],"segments":[],"summary":null,"chapters":[],"todos":[]}}}"#
                )
            )
        }
        let d = try await makeAPI().minuteDetail(token: "t")
        XCTAssertNil(d.summary)
        XCTAssertEqual(d.minute.status, .unknown)
    }

    func testRecordingProtocolEndpoints() async throws {
        StubURLProtocol.install { req in
            switch req.url?.path {
            case "/trpc/recording.begin": return (200, json(#"{"result":{"data":{"sessionId":"S1"}}}"#))
            case "/trpc/recording.status":
                return (
                    200,
                    json(
                        #"{"result":{"data":{"sessionId":"S1","status":"OPEN","receivedSeqs":[2,0],"expectedSegments":null,"minuteId":null,"token":null,"errorMessage":null}}}"#
                    )
                )
            case "/trpc/recording.finalize":
                return (200, json(#"{"result":{"data":{"minuteId":"M1","token":"T1"}}}"#))
            default: return (404, Data())
            }
        }
        let api = makeAPI()
        let begin = try await api.beginRecording(
            RecordingBeginInput(
                title: nil, startedAt: Date(timeIntervalSince1970: 1_790_000_000), language: "zh",
                clientSessionId: "c0ffee00-0000-4000-8000-000000000000"))
        XCTAssertEqual(begin.sessionId, "S1")
        let status = try await api.recordingStatus(sessionId: "S1")
        XCTAssertEqual(status.receivedSeqs, [0, 2])
        let fin = try await api.finalizeRecording(sessionId: "S1", expectedSegments: 3)
        XCTAssertEqual(fin, RecordingFinalizeOutput(minuteId: "M1", token: "T1"))

        let reqs = StubURLProtocol.requests
        let beginBody = try XCTUnwrap(reqs[0].body)
        let beginObj = try XCTUnwrap(try JSONSerialization.jsonObject(with: beginBody) as? [String: Any])
        XCTAssertEqual(beginObj["clientSessionId"] as? String, "c0ffee00-0000-4000-8000-000000000000")
        XCTAssertEqual(beginObj["startedAt"] as? String, "2026-09-21T14:13:20.000Z")
        XCTAssertEqual(beginObj["language"] as? String, "zh")
        XCTAssertNil(beginObj["title"], "没有标题时不发 title 字段")
        let finObj = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(reqs[2].body)) as? [String: Any])
        XCTAssertEqual(finObj["expectedSegments"] as? Int, 3)
        for r in reqs {
            XCTAssertEqual(r.request.value(forHTTPHeaderField: "X-Device-Token"), "dev-token-123")
        }
    }

    func testStatusDecodesW1ContractShape() throws {
        let d = WendaoJSON.decoder()
        let full = try d.decode(
            RecordingStatusOutput.self,
            from: json(
                #"{"sessionId":"S","status":"DONE","receivedSeqs":[1,0],"expectedSegments":2,"minuteId":"M","token":"T","errorMessage":null}"#
            ))
        XCTAssertEqual(full.receivedSeqs, [0, 1])
        XCTAssertEqual(full.expectedSegments, 2)
        XCTAssertEqual(full.finalizedMinute, RecordingFinalizeOutput(minuteId: "M", token: "T"))
        let open = try d.decode(
            RecordingStatusOutput.self,
            from: json(
                #"{"sessionId":"S","status":"OPEN","receivedSeqs":[],"expectedSegments":null,"minuteId":null,"token":null,"errorMessage":null}"#
            ))
        XCTAssertNil(open.finalizedMinute)
        XCTAssertThrowsError(try d.decode(RecordingStatusOutput.self, from: json(#"{"status":"OPEN"}"#)))
    }

    func testSegmentUploadSendsTokenAndMaps409() async throws {
        let dir = try makeTempDirectory()
        let file = dir.appendingPathComponent("seg-00001.m4a")
        let data = try writeFakeAudio(file, seq: 1)
        let upload = SegmentUpload(
            sessionId: "S1", seq: 1, sha256: FileDigest.sha256Hex(of: data), fileURL: file, fileName: "seg-00001.m4a")

        StubURLProtocol.install { _ in
            (200, json(#"{"sessionId":"S1","seq":1,"sha256":"x","sizeBytes":2062,"duplicate":false}"#))
        }
        try await makeAPI().uploadSegment(upload)
        let req = try XCTUnwrap(StubURLProtocol.requests.first).request
        XCTAssertEqual(req.url?.path, "/upload/segment")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Device-Token"), "dev-token-123")
        XCTAssertTrue(req.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") ?? false)

        StubURLProtocol.install { _ in
            (409, json(#"{"error":"segment conflict","message":"同一序号已存在内容不同的分段","seq":1,"existingSha256":"ab"}"#))
        }
        do {
            try await makeAPI().uploadSegment(upload)
            XCTFail("409 应抛错")
        } catch let e as WendaoAPIError {
            XCTAssertEqual(e, .conflict("segment conflict"))
        }

        StubURLProtocol.install { _ in
            (409, json(#"{"error":"session closed","message":"该录音会话已不再接收新分段","status":"DONE"}"#))
        }
        do {
            try await makeAPI().uploadSegment(upload)
            XCTFail("会话已关闭应抛错")
        } catch let e as WendaoAPIError {
            XCTAssertEqual(e, .sessionClosed("该录音会话已不再接收新分段"))
        }

        StubURLProtocol.install { _ in (401, json(#"{"error":"unauthorized"}"#)) }
        do {
            try await makeAPI(token: "revoked").uploadSegment(upload)
            XCTFail("401 应抛错")
        } catch let e as WendaoAPIError {
            XCTAssertEqual(e, .unauthorized)
        }
    }

    func testMultipartBodyLayout() throws {
        let dir = try makeTempDirectory()
        let file = dir.appendingPathComponent("a.m4a")
        try Data([0x00, 0x01, 0x02]).write(to: file)
        var body = MultipartBody(boundary: "B")
        body.addField("sessionId", "S1")
        body.addField("seq", "0")
        body.addField("sha256", "abc")
        let out = dir.appendingPathComponent("body")
        let n = try body.write(fileField: "file", fileURL: file, fileName: "seg-00000.m4a", mimeType: "audio/mp4", to: out)
        var expected = Data(
            ("--B\r\nContent-Disposition: form-data; name=\"sessionId\"\r\n\r\nS1\r\n"
                + "--B\r\nContent-Disposition: form-data; name=\"seq\"\r\n\r\n0\r\n"
                + "--B\r\nContent-Disposition: form-data; name=\"sha256\"\r\n\r\nabc\r\n"
                + "--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"seg-00000.m4a\"\r\n"
                + "Content-Type: audio/mp4\r\n\r\n").utf8)
        expected.append(contentsOf: [0x00, 0x01, 0x02])
        expected.append(Data("\r\n--B--\r\n".utf8))
        XCTAssertEqual(try Data(contentsOf: out), expected)
        XCTAssertEqual(n, expected.count)
    }

    func testBaseURLNormalization() {
        XCTAssertEqual(WendaoServer.normalizedBaseURL(" http://192.168.1.20:3101/ ")?.absoluteString, "http://192.168.1.20:3101")
        XCTAssertNil(WendaoServer.normalizedBaseURL("ftp://x"))
        XCTAssertNil(WendaoServer.normalizedBaseURL("wendao"))
        XCTAssertEqual(WendaoServer.production.absoluteString, "https://wendao.chengqiyun.com")
    }
}
