// easy-rpc Swift core: zero-runtime-bindings Transport + Connect wire
// (unary + server-stream). URLSession (Foundation) bridge, HTTP/1.1.
import Foundation
import SwiftProtobuf

public typealias Headers = [String: [String]]

/// A structured error detail (spec §4.1, aligned with Connect Error Details /
/// gRPC google.rpc status details). `type` is a type URL; `value` is opaque
/// bytes (typically an encoded protobuf message).
public struct ErrorDetail: Sendable, Equatable, CustomStringConvertible {
    public let type: String
    public let value: Data
    public init(type: String, value: Data) { self.type = type; self.value = value }
    public static func == (l: ErrorDetail, r: ErrorDetail) -> Bool {
        l.type == r.type && l.value == r.value
    }
    public var description: String { "ErrorDetail(\(type), \(value.count)B)" }
}

public struct RPCError: Error, CustomStringConvertible {
    public let code: Int
    public let message: String
    /// Optional structured details (spec §4.1); opaque to the wire layer.
    public let details: [ErrorDetail]?
    public init(code: Int, message: String, details: [ErrorDetail]? = nil) {
        self.code = code; self.message = message; self.details = details
    }
    public var description: String { "easyrpc: code=\(code) \(message)" }
}

public struct Request {
    public var url: String
    public var headers: Headers
    public var body: Data?
    /// Local cancellation handle. Adapters race this against the call.
    public var cancelled: @Sendable () -> Bool
    public init(
        url: String,
        headers: Headers = [:],
        body: Data? = nil,
        cancelled: @escaping @Sendable () -> Bool = { false }
    ) {
        self.url = url; self.headers = headers; self.body = body
        self.cancelled = cancelled
    }
}

public struct Response {
    public var status: Int
    public var headers: Headers
    public var body: Data
    /// Unary trailing metadata (demuxed from `trailer-*` response headers).
    public var trailers: Headers
    public var error: RPCError?
}

public func httpStatus(_ code: Int) -> Int {
    switch code {
    case 1: 499; case 3: 400; case 4: 504; case 5: 404; case 6: 409; case 7: 403;
    case 8: 429; case 9: 400; case 10: 409; case 11: 400; case 12: 501;
    case 14: 503; case 16: 401; default: 500
    }
}

public func connectFromStatus(_ s: Int) -> Int {
    switch s {
    case 400: 3; case 404: 5; case 403: 7; case 401: 16; case 429: 8; case 503: 14;
    case 409: 10; case 504: 4; case 501: 12; case 499: 1; default: 13
    }
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
/// The decompress hook returns nil on CORRUPT input (fault matrix M10): the
/// frame scanner turns that into RPCError(13), never raw compressed bytes.
public var gzipCompressHook: (@Sendable (Data) -> Data)? = nil
public var gzipDecompressHook: (@Sendable (Data) -> Data?)? = nil

public func gzipCompress(_ data: Data) -> Data { gzipCompressHook?(data) ?? data }
public func gzipDecompress(_ data: Data) -> Data? { gzipDecompressHook?(data) ?? nil }

/// Incremental frame scanner (fault matrix F1/F2/F5/M8/M10): feed it raw
/// stream bytes, pull complete frames out, and call `finish()` at source end —
/// it errors on trailing partial bytes or a missing END frame.
public final class FrameScanner {
    private var acc = Data()
    private var sawEnd = false
    private(set) public var error: RPCError?
    private(set) public var trailers: Headers = [:]

    public init() {}

    /// Feed raw bytes; returns the complete DATA payloads found (the END frame
    /// terminates the stream and is not returned).
    public func push(_ chunk: Data) -> [Data] {
        guard error == nil else { return [] }
        acc.append(chunk)
        var out: [Data] = []
        while error == nil {
            guard acc.count >= 5 else { break }
            let flags = acc[acc.startIndex]
            var lenbe: UInt32 = 0
            withUnsafeMutableBytes(of: &lenbe) { p in
                _ = acc.copyBytes(to: p.bindMemory(to: UInt8.self), from: acc.startIndex+1..<acc.startIndex+5)
            }
            let len = Int(UInt32(bigEndian: lenbe))
            if acc.count < 5 + len { break }
            var payload = acc.subdata(in: acc.startIndex+5..<acc.startIndex+5+len)
            acc.removeFirst(5 + len)
            if flags & 0x01 != 0 {
                guard let plain = gzipDecompress(payload) else {
                    error = RPCError(code: 13, message: "corrupt gzip frame")
                    return out
                }
                payload = plain
            }
            if flags & kEndStream != 0 {
                sawEnd = true
                let es = decodeEndStream(payload)
                if !es.metadata.isEmpty { trailers = es.metadata }
                if es.code != 0 { error = RPCError(code: es.code, message: es.message, details: es.details) }
                return out
            }
            out.append(payload)
        }
        return out
    }

    /// Source ended. The Connect protocol requires every server-stream to
    /// terminate with an END frame; trailing partial bytes or a missing END
    /// frame mean the stream was truncated mid-flight (F2/M8).
    public func finish() {
        guard error == nil else { return }
        if !acc.isEmpty {
            error = RPCError(code: 13, message: "truncated frame at end of stream")
        } else if !sawEnd {
            error = RPCError(code: 13, message: "stream ended without END frame")
        }
    }
}

func wireDetails(_ details: [ErrorDetail]?) -> [[String: String]] {
    // UNPADDED standard base64 — matches Connect (base64.RawStdEncoding).
    (details ?? []).map { ["type": $0.type, "value": $0.value.base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))] }
}

/// Decode standard OR URL-safe base64, padded OR unpadded.
func b64DecodeLenient(_ s: String) -> Data? {
    var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    if t.count % 4 == 1 { return nil }
    while t.count % 4 != 0 { t += "=" }
    return Data(base64Encoded: t)
}

/// Parse a JSON details array; malformed entries are skipped, never fatal
/// (matrix M7). Returns nil when absent/empty.
func parseWireDetails(_ v: Any?) -> [ErrorDetail]? {
    guard let arr = v as? [[String: Any]] ?? (v as? [Any])?.compactMap({ $0 as? [String: Any] }) else { return nil }
    var out: [ErrorDetail] = []
    for el in arr {
        guard let t = el["type"] as? String, !t.isEmpty,
              let val = el["value"] as? String, !val.isEmpty,
              let bytes = b64DecodeLenient(val) else { continue }
        out.append(ErrorDetail(type: t, value: bytes))
    }
    return out.isEmpty ? nil : out
}

/// Encode a Connect unary error body {code,message[,details]}.
public func encodeErrorJson(_ code: Int, _ message: String, _ details: [ErrorDetail]? = nil) -> Data {
    var obj: [String: Any] = ["code": codeToString(code), "message": message]
    let wire = wireDetails(details)
    if !wire.isEmpty { obj["details"] = wire }
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return Data() }
    return data
}

/// Parse a Connect unary error body; (0, "", nil) when not one.
public func decodeErrorJson(_ body: Data) -> (code: Int, message: String, details: [ErrorDetail]?) {
    if body.isEmpty { return (0, "", nil) }
    guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
          let code = obj["code"] as? String else { return (0, "", nil) }
    return (codeFromString(code), (obj["message"] as? String) ?? "", parseWireDetails(obj["details"]))
}

/// Encode a Connect end-stream payload; a clean end is empty. Details
/// (spec §4.1) are included when non-empty.
public func encodeEndStream(_ code: Int, _ message: String, _ details: [ErrorDetail]? = nil,
                           _ metadata: Headers = [:]) -> Data {
    var obj: [String: Any] = [:]
    if code != 0 {
        var err: [String: Any] = ["code": codeToString(code), "message": message]
        let wire = wireDetails(details)
        if !wire.isEmpty { err["details"] = wire }
        obj["error"] = err
    }
    let md = metadata.filter { !$0.value.isEmpty }
    if !md.isEmpty { obj["metadata"] = md }
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return Data() }
    return data
}

/// A decoded END frame: code/message/details + trailing metadata.
public struct EndStream {
    public let code: Int
    public let message: String
    public let details: [ErrorDetail]?
    public let metadata: Headers
    public init(code: Int, message: String, details: [ErrorDetail]?, metadata: Headers) {
        self.code = code; self.message = message; self.details = details; self.metadata = metadata
    }
}

/// Split headers into (headers, trailers) by the `trailer-` prefix.
public func demuxTrailers(_ all: Headers) -> (headers: Headers, trailers: Headers) {
    var h: Headers = [:]; var t: Headers = [:]
    for (k, v) in all {
        if k.lowercased().hasPrefix("trailer-") {
            t[String(k.lowercased().dropFirst(8))] = v
        } else { h[k] = v }
    }
    return (h, t)
}

/// Merge trailers into headers using the `trailer-` prefix.
public func muxTrailers(_ headers: Headers, _ trailers: Headers) -> Headers {
    var out = headers
    for (k, v) in trailers { out["trailer-\(k.lowercased())"] = v }
    return out
}

/// Per-RPC context for generated handlers: request metadata + trailer channel.
public final class HandlerContext: @unchecked Sendable {
    public let headers: Headers
    private var _trailers: Headers = [:]
    public init(headers: Headers = [:]) { self.headers = headers }
    public func setTrailer(_ key: String, _ value: String) {
        _trailers[key, default: []].append(value)
    }
    public var trailers: Headers { _trailers }
}

public let contentTypeUnary = "application/proto"
public let contentTypeStream = "application/connect+proto"
public let contentTypeUnaryJson = "application/json"
public let contentTypeStreamJson = "application/connect+json"

/// Map a Content-Type to a codec ("proto" | "json"), or nil when unsupported.
public func contentKindOf(_ contentType: String?) -> String? {
    let ct = (contentType ?? "").split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
    switch ct {
    case "application/proto", "application/connect+proto": return "proto"
    case "application/json", "application/connect+json": return "json"
    default: return nil
    }
}

/// True when the content type denotes the streaming shape.
public func isStreamContentType(_ contentType: String?) -> Bool {
    let ct = (contentType ?? "").split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
    return ct == "application/connect+proto" || ct == "application/connect+json"
}

/// The response Content-Type for a shape + codec.
public func contentTypeFor(_ stream: Bool, _ kind: String) -> String {
    if kind == "json" { return stream ? contentTypeStreamJson : contentTypeUnaryJson }
    return stream ? contentTypeStream : contentTypeUnary
}

/// Encode a SwiftProtobuf message in the given codec (JSON uses the canonical
/// proto3 mapping: lowerCamelCase, bytes base64, Any `@type`).
public func encodeMsg<M: SwiftProtobuf.Message>(_ msg: M, _ kind: String) throws -> Data {
    if kind == "json" { return Data(try msg.jsonString().utf8) }
    return try msg.serializedData()
}

/// Decode bytes into a SwiftProtobuf message in the given codec. JSON ignores
/// unknown fields (matching Connect / protojson).
public func decodeMsg<M: SwiftProtobuf.Message>(_ data: Data, _ type: M.Type, _ kind: String) throws -> M {
    if kind == "json" {
        var opts = JSONDecodingOptions()
        opts.ignoreUnknownFields = true
        return try M(jsonUTF8Bytes: data, options: opts)
    }
    return try M(serializedBytes: data)
}

/// Decode a Connect end-stream payload into (code, message, details);
/// (0, "", nil) = clean end. Malformed input is a clean end (matrix M2); an
/// error object without a code maps to 2 (M3/M4); unknown fields ignored (M5).
public func decodeEndStream(_ payload: Data) -> EndStream {
    if payload.isEmpty { return EndStream(code: 0, message: "", details: nil, metadata: [:]) }
    guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
        return EndStream(code: 0, message: "", details: nil, metadata: [:])
    }
    var metadata: Headers = [:]
    if let md = obj["metadata"] as? [String: [String]] {
        metadata = md.filter { !$0.value.isEmpty }
    }
    guard let e = obj["error"] as? [String: Any] else {
        return EndStream(code: 0, message: "", details: nil, metadata: metadata)
    }
    let code = (e["code"] as? String).map { codeFromString($0) } ?? 2
    return EndStream(code: code, message: (e["message"] as? String) ?? "",
                     details: parseWireDetails(e["details"]), metadata: metadata)
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
    private var sawEnd = false
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
            if (flags & 0x01) != 0 {
                // M10: corrupt gzip is a protocol error, never raw bytes.
                guard let plain = gzipDecompress(payload) else {
                    out.append(Frameish(payload: Data(), end: true))
                    return out
                }
                payload = plain
            }
            let end = (flags & kEndStream) != 0
            if end { sawEnd = true }
            out.append(Frameish(payload: payload, end: end))
        }
        return out
    }

    /// Source ended (fault matrix F2/M8): trailing partial bytes or a missing
    /// END frame mean the stream was truncated mid-flight.
    public mutating func finish() throws {
        if !acc.isEmpty {
            throw RPCError(code: 13, message: "truncated frame at end of stream")
        }
        if !sawEnd {
            throw RPCError(code: 13, message: "stream ended without END frame")
        }
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
    return Request(url: req.url, headers: h, body: req.body)
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
    /// Trailing metadata from the END frame (available after the stream ends).
    func trailers() -> Headers
    func cancel()
}

public extension Stream {
    func lastError() -> RPCError? { nil }
    func trailers() -> Headers { [:] }
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
        return Request(url: req.url, headers: h, body: req.body)
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

