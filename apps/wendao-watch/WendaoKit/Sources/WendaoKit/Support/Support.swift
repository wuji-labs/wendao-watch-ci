// Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)

import Foundation

#if canImport(CryptoKit)
    import CryptoKit
#endif

/// 文件摘要：分块读取，避免把整段音频读进内存。
public enum FileDigest {
    public static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        #if canImport(CryptoKit)
            var hasher = SHA256()
        #else
            var hasher = PortableSHA256()
        #endif
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(Array(hasher.finalize()))
    }

    public static func sha256Hex(of data: Data) -> String {
        #if canImport(CryptoKit)
            return hex(Array(SHA256.hash(data: data)))
        #else
            var hasher = PortableSHA256()
            hasher.update(data: data)
            return hex(hasher.finalize())
        #endif
    }

    static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef")
        var out = ""
        out.reserveCapacity(bytes.count * 2)
        for b in bytes {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0f)])
        }
        return out
    }
}

/// 统一的时间编码：ISO 8601，带毫秒，UTC。服务端 `z.string().datetime()` 与 `z.coerce.date()` 均可接收。
public enum WendaoDate {
    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let withoutFraction = Date.ISO8601FormatStyle()

    public static func string(from date: Date) -> String {
        withFraction.format(date)
    }

    public static func date(from string: String) -> Date? {
        if let d = try? withFraction.parse(string) { return d }
        return try? withoutFraction.parse(string)
    }
}

public enum WendaoJSON {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(WendaoDate.string(from: date))
        }
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self), let date = WendaoDate.date(from: s) {
                return date
            }
            if let ms = try? c.decode(Double.self) {
                return Date(timeIntervalSince1970: ms / 1000)
            }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "无法解析的时间值")
        }
        return d
    }
}

/// 可注入的时钟，测试用固定时间推进。
public struct WendaoClock: Sendable {
    public var now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date) {
        self.now = now
    }

    public static let system = WendaoClock { Date() }
}

extension FileManager {
    /// 原子写：先写临时文件再替换，进程中途被杀也不会留下半个 JSON。
    static func writeAtomically(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }
}
