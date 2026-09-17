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
    /// Local cancellation handle. Adapters race this against the call.
    public var cancelled: @Sendable () -> Bool
    public init(
        url: String,
        method: String = "POST",
        headers: Headers = [:],
        body: Data? = nil,
        cancelled: @escaping @Sendable () -> Bool = { false }
    ) {
        self.url = url; self.method = method; self.headers = headers; self.body = body
        self.cancelled = cancelled
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

/// gzip hooks. Core has no platform dependency: runtimes that support gzip
/// install these (e.g. the URLSession/AsyncHTTP bridges on platforms with zlib).
public var gzipCompressHook: (@Sendable (Data) -> Data)? = nil
public var gzipDecompressHook: (@Sendable (Data) -> Data)? = nil

public func gzipCompress(_ data: Data) -> Data { gzipCompressHook?(data) ?? data }
public func gzipDecompress(_ data: Data) -> Data { gzipDecompressHook?(data) ?? data }

/// Encode a Connect unary error body {code,message}.
public func encodeErrorJson(_ code: Int, _ message: String) -> Data {
    let esc = message.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    let json = "{\"code\":\"\(codeToString(code))\",\"message\":\"\(esc)\"}"
    return Data(json.utf8)
}

/// Parse a Connect unary error body; (0, "") when not one.
public func decodeErrorJson(_ body: Data) -> (code: Int, message: String) {
    if body.isEmpty { return (0, "") }
    guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
          let code = obj["code"] as? String else { return (0, "") }
    return (codeFromString(code), (obj["message"] as? String) ?? "")
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
            var payload = acc.subdata(in: acc.startIndex+5..<acc.startIndex+5+length)
            acc.removeFirst(5 + length)
            if (flags & 0x01) != 0 { payload = gzipDecompress(payload) }
            out.append(Frameish(payload: payload, end: (flags & kEndStream) != 0))
        }
        return out
    }
}

public let kHeaderTimeout = "connect-timeout-ms"
public let kHeaderProtocolVersion = "connect-protocol-version"
public let kHeaderAcceptEncoding = "connect-accept-encoding"
public let kEncodingGzip = "gzip"
public let kCompressMinBytes = 1024
public let kConnectProtocolVersion = "1"
public let kDefaultMaxMessageBytes = 4 * 1024 * 1024

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

/// Adapter mode for the Swift composition root.
public enum TransportMode: Sendable { case auto, urlSession, asyncHTTPClient }

/// Composition root: pick an adapter by `mode`, install the built-in
/// metadata/deadline interceptors, then any `extra`. Swapping `mode` leaves the
/// interceptors unchanged.
public func connect(
    baseUrl: String,
    token: String = "",
    mode: TransportMode = .auto,
    timeoutMs: Int = 0,
    extra: [any Interceptor] = [],
    transport: (any Transport)? = nil
) -> any Transport {
    let base = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
    let inner: any Transport = transport ?? {
        switch mode {
        case .asyncHTTPClient: return AsyncHTTPClientTransport(base: base)
        case .urlSession, .auto: return URLSessionTransport(base: base)
        }
    }()
    var ics: [any Interceptor] = []
    if !token.isEmpty { ics.append(MetadataInterceptor(["authorization": ["Bearer \(token)"]])) }
    if timeoutMs > 0 { ics.append(TimeoutInterceptor(timeoutMs)) }
    ics.append(contentsOf: extra)
    return ics.isEmpty ? inner : InterceptorTransport(ics, inner)
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

/// A call interceptor: mutate the request (auth/metadata), impose a deadline,
/// observe, or short-circuit. `next` performs the call.
public protocol Interceptor: Sendable {
    func unary(_ req: Request, _ next: @Sendable (Request) async throws -> Response) async throws -> Response
    func stream(_ req: Request, _ next: @Sendable (Request) async throws -> any Stream) async throws -> any Stream
}

public extension Interceptor {
    func unary(_ req: Request, _ next: @Sendable (Request) async throws -> Response) async throws -> Response {
        try await next(req)
    }
    func stream(_ req: Request, _ next: @Sendable (Request) async throws -> any Stream) async throws -> any Stream {
        try await next(req)
    }
}

/// Apply interceptors (first = outermost) around a Transport.
public struct InterceptorTransport: Transport {
    private let ics: [any Interceptor]
    private let inner: any Transport
    public init(_ ics: [any Interceptor], _ inner: any Transport) { self.ics = ics; self.inner = inner }

    private func dispatchUnary(_ i: Int, _ r: Request) async throws -> Response {
        if i >= ics.count { return try await inner.send(r) }
        let ic = ics[i]
        return try await ic.unary(r) { nr in try await dispatchUnary(i + 1, nr) }
    }
    private func dispatchStream(_ i: Int, _ r: Request) async throws -> any Stream {
        if i >= ics.count { return try await inner.openStream(r) }
        let ic = ics[i]
        return try await ic.stream(r) { nr in try await dispatchStream(i + 1, nr) }
    }
    public func send(_ req: Request) async throws -> Response { try await dispatchUnary(0, req) }
    public func openStream(_ req: Request) async throws -> any Stream { try await dispatchStream(0, req) }
}

/// Attach fixed metadata to every call.
public struct MetadataInterceptor: Interceptor {
    public let md: Headers
    public init(_ md: Headers) { self.md = md }
    private func aug(_ req: Request) -> Request {
        var h = req.headers
        for (k, v) in md where h[k] == nil { h[k] = v }
        return Request(url: req.url, method: req.method, headers: h, body: req.body)
    }
    public func unary(_ req: Request, _ next: @Sendable (Request) async throws -> Response) async throws -> Response {
        try await next(aug(req))
    }
    public func stream(_ req: Request, _ next: @Sendable (Request) async throws -> any Stream) async throws -> any Stream {
        try await next(aug(req))
    }
}

/// Attach a Connect deadline to every call; enforces locally by racing a
/// task against the deadline, so it works over any adapter.
public final class TimeoutInterceptor: Interceptor, @unchecked Sendable {
    private let ms: Int
    private let lock = NSLock()
    private var fired = false
    public init(_ ms: Int) { self.ms = ms }

    private func run<T>(_ req: Request, _ next: @escaping @Sendable (Request) async throws -> T) async throws -> T {
        if ms <= 0 { return try await next(req) }
        var r = withTimeout(req, ms)
        r.cancelled = { [weak self] in
            guard let self else { return false }
            self.lock.lock(); defer { self.lock.unlock() }
            return self.fired
        }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await next(r) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.ms) * 1_000_000)
                self.lock.lock(); self.fired = true; self.lock.unlock()
                throw RPCError(code: 4, message: "deadline exceeded")
            }
            defer { group.cancelAll(); self.lock.lock(); self.fired = false; self.lock.unlock() }
            return try await group.next()!
        }
    }

    public func unary(_ req: Request, _ next: @escaping @Sendable (Request) async throws -> Response) async throws -> Response {
        try await run(req, next)
    }
    public func stream(_ req: Request, _ next: @escaping @Sendable (Request) async throws -> any Stream) async throws -> any Stream {
        try await run(req, next)
    }
}

/// Core interface a bridge implements.
public protocol Transport: Sendable {
    func send(_ req: Request) async throws -> Response
    func openStream(_ req: Request) async throws -> any Stream
}

