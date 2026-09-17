// easy-rpc Swift core: zero-runtime-bindings Transport + Connect wire
// (unary + server-stream). URLSession (Foundation) bridge, HTTP/1.1.
import Foundation
import SwiftProtobuf

public typealias Headers = [String: [String]]

public struct RPCError: Error, CustomStringConvertible {
    public let code: Int
    public let message: String
    public var description: String { "easyrpc: code=\(code) \(message)" }
}

public struct Request {
    public var url: String
    public var method: String
    public var headers: Headers
    public var body: Data?
    public init(url: String, method: String = "POST", headers: Headers = [:], body: Data? = nil) {
        self.url = url; self.method = method; self.headers = headers; self.body = body
    }
}

public struct Response {
    public var status: Int
    public var headers: Headers
    public var body: Data
    public var error: RPCError?
}

public func httpStatus(_ code: Int) -> Int {
    switch code { case 3: 400; case 5: 404; case 7: 403; case 8: 429; case 16: 401; case 14: 503; default: 500 }
}

public func connectFromStatus(_ s: Int) -> Int {
    switch s { case 400: 3; case 404: 5; case 403: 7; case 401: 16; case 429: 8; case 503: 14; default: 13 }
}

public let kEndStream: UInt8 = 0x02

public let kCodeNames: [Int: String] = [
    0: "ok", 1: "canceled", 2: "unknown", 3: "invalid_argument",
    4: "deadline_exceeded", 5: "not_found", 6: "already_exists",
    7: "permission_denied", 8: "resource_exhausted", 9: "failed_precondition",
    10: "aborted", 11: "out_of_range", 12: "unimplemented", 13: "internal",
    14: "unavailable", 15: "data_loss", 16: "unauthenticated",
]

public func codeToString(_ code: Int) -> String { kCodeNames[code] ?? "unknown" }
public func codeFromString(_ name: String) -> Int {
    for (c, n) in kCodeNames where n == name { return c }
    return 2
}

/// Encode a Connect end-stream payload; a clean end is empty.
public func encodeEndStream(_ code: Int, _ message: String) -> Data {
    if code == 0 { return Data() }
    let esc = message.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    let json = "{\"error\":{\"code\":\"\(codeToString(code))\",\"message\":\"\(esc)\"}}"
    return Data(json.utf8)
}

/// Decode a Connect end-stream payload into (code, message); (0, "") clean.
public func decodeEndStream(_ payload: Data) -> (code: Int, message: String) {
    if payload.isEmpty { return (0, "") }
    guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
          let e = obj["error"] as? [String: Any] else { return (0, "") }
    let code = (e["code"] as? String).map { codeFromString($0) } ?? 2
    return (code, (e["message"] as? String) ?? "")
}

public func frame(_ payload: Data, end: Bool = false) -> Data {
    var out = Data([end ? kEndStream : 0])
    withUnsafeBytes(of: UInt32(payload.count).bigEndian) { out.append(contentsOf: $0) }
    out.append(payload)
    return out
}

/// One decoded frame: payload + whether it is the END frame.
public struct Frameish { public let payload: Data; public let end: Bool }

/// De-frames a server-stream byte stream into typed frames.
public struct FrameReader {
    private var acc = Data()
    public init() {}
    public mutating func push(_ chunk: Data) -> [Frameish] {
        acc.append(chunk)
        var out: [Frameish] = []
        while true {
            if acc.count < 5 { break }
            let flags = acc[acc.startIndex]
            var lenVal: UInt32 = 0
            withUnsafeMutableBytes(of: &lenVal) { ptr in
                _ = acc.copyBytes(to: ptr.bindMemory(to: UInt8.self), from: acc.startIndex+1..<acc.startIndex+5)
            }
            let length = Int(UInt32(bigEndian: lenVal))
            if acc.count < 5 + length { break }
            let payload = acc.subdata(in: acc.startIndex+5..<acc.startIndex+5+length)
            acc.removeFirst(5 + length)
            out.append(Frameish(payload: payload, end: (flags & kEndStream) != 0))
        }
        return out
    }
}

public let kHeaderTimeout = "connect-timeout-ms"

/// Parse the Connect timeout header into milliseconds (0 = none).
public func parseTimeout(_ value: String?) -> Int {
    guard let v = value, let n = Int(v), n > 0 else { return 0 }
    return n
}

/// Attach a deadline to a request.
public func withTimeout(_ req: Request, _ timeoutMs: Int) -> Request {
    if timeoutMs <= 0 { return req }
    var h = req.headers
    h[kHeaderTimeout] = [String(timeoutMs)]
    return Request(url: req.url, method: req.method, headers: h, body: req.body)
}

/// Protocol-agnostic server-stream.
public protocol Stream: Sendable {
    func recv() async -> Data?
    /// Set when the stream ended with a Connect end-stream error.
    func lastError() -> RPCError?
    func cancel()
}

public extension Stream {
    func lastError() -> RPCError? { nil }
}

/// Core interface a bridge implements.
public protocol Transport: Sendable {
    func send(_ req: Request) async throws -> Response
    func openStream(_ req: Request) async throws -> any Stream
}

