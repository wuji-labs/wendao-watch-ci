// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import Foundation

/// multipart/form-data 请求体，直接流式写入临时文件（后台上传只接受文件作为请求体）。
///
/// 字段写在文件之前：服务端 `@fastify/multipart` 的 `req.file()` 只能看到文件之前出现的字段。
public struct MultipartBody: Sendable {
    public let boundary: String
    public private(set) var fields: [(name: String, value: String)]

    public init(boundary: String = "WendaoBoundary-" + UUID().uuidString) {
        self.boundary = boundary
        self.fields = []
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public mutating func addField(_ name: String, _ value: String) {
        fields.append((name, value))
    }

    /// 把字段与文件写到 `destination`，返回写入的总字节数。
    @discardableResult
    public func write(
        fileField: String, fileURL: URL, fileName: String, mimeType: String, to destination: URL
    ) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        guard fm.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        var total = 0
        func put(_ s: String) throws {
            let d = Data(s.utf8)
            try out.write(contentsOf: d)
            total += d.count
        }
        for field in fields {
            try put("--\(boundary)\r\n")
            try put("Content-Disposition: form-data; name=\"\(Self.escape(field.name))\"\r\n\r\n")
            try put("\(field.value)\r\n")
        }
        try put("--\(boundary)\r\n")
        try put(
            "Content-Disposition: form-data; name=\"\(Self.escape(fileField))\"; filename=\"\(Self.escape(fileName))\"\r\n"
        )
        try put("Content-Type: \(mimeType)\r\n\r\n")
        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
            total += chunk.count
        }
        try put("\r\n--\(boundary)--\r\n")
        return total
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }
}
