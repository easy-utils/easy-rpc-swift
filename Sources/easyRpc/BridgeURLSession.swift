// URLSession bridge (FoundationNetworking on Linux, Foundation on Apple).
// unary -> data(for:); streaming -> URLSession data task with chunked read.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class URLSessionTransport: Transport, @unchecked Sendable {
    private let session: URLSession
    public var base: String
    convenience public init(base: String = "") { self.init(session: .shared, base: base) }
    public init(session: URLSession, base: String = "") { self.session = session; self.base = base }
    private func _url(_ u: String) -> String { u.hasPrefix("http") ? u : base + u }

    public func send(_ req: Request) async throws -> Response {
        var r = URLRequest(url: URL(string: _url(req.url))!)
        r.httpMethod = "POST"
        r.httpBody = req.body
        if !req.headers.keys.contains(where: { $0.lowercased() == "content-type" }) {
            // Caller content-type wins (the JSON codec depends on it).
            r.setValue("application/proto", forHTTPHeaderField: "content-type")
        }
        for (k, vs) in req.headers { for v in vs { r.setValue(v, forHTTPHeaderField: k) } }
        let (rawData, resp) = try await session.data(for: r)
        let http = resp as! HTTPURLResponse
        let s = http.statusCode
        var data = rawData
        let all = normalizeHeaders(http.allHeaderFields)
        if let ce = all["content-encoding"]?.first, ce == "gzip", !data.isEmpty,
           let plain = gzipDecompress(data) {
            data = plain
        }
        let (hdrs, trailers) = demuxTrailers(all)
        return Response(status: s, headers: hdrs, body: data, trailers: trailers,
                        error: s >= 300 ? rpcError(status: s, headers: http.allHeaderFields, body: data) : nil)
    }

    public func openStream(_ req: Request) async throws -> any Stream {
        var r = URLRequest(url: URL(string: _url(req.url))!)
        r.httpMethod = "POST"
        r.httpBody = req.body
        if !req.headers.keys.contains(where: { $0.lowercased() == "content-type" }) {
            // Caller content-type wins (the JSON codec depends on it).
            r.setValue("application/connect+proto", forHTTPHeaderField: "content-type")
        }
        for (k, vs) in req.headers { for v in vs { r.setValue(v, forHTTPHeaderField: k) } }
        // URLSession.data buffers the whole body, but the SERVER now responds
        // 200 immediately and streams frames; on Linux URLSession buffers until
        // the connection closes, so for live incrementality use
        // AsyncHTTPClientTransport instead. This bridge still works for
        // short/closed streams.
        let (full, resp) = try await session.data(for: r)
        let s = (resp as! HTTPURLResponse).statusCode
        if s >= 300 { throw rpcError(status: s, headers: (resp as! HTTPURLResponse).allHeaderFields, body: full) }
        return BufferedStream(data: full)
    }

    private func normalizeHeaders(_ h: [AnyHashable: Any]) -> Headers {
        var out: Headers = [:]
        for (k, v) in h {
            guard let key = k as? String else { continue }
            if let arr = v as? [String] { out[key.lowercased()] = arr }
            else if let s = v as? String { out[key.lowercased()] = [s] }
        }
        return out
    }

    /// Reconstruct the exact RPCError from connect-code/connect-error.
    private func rpcError(status: Int, headers: [AnyHashable: Any], body: Data) -> RPCError {
        if let c = headers["connect-code"] as? String, let code = Int(c) {
            return RPCError(code: code, message: headers["connect-error"] as? String ?? "", details: decodeErrorJson(body).details)
        }
        let (jc, jm, jd) = decodeErrorJson(body)
        if jc != 0 { return RPCError(code: jc, message: jm, details: jd) }
        return RPCError(code: connectFromStatus(status), message: String(data: body, encoding: .utf8) ?? "")
    }
}

/// Streams from an in-memory byte buffer by de-framing.
private final class BufferedStream: Stream, @unchecked Sendable {
    private let scanner = FrameScanner()
    private var payloads: [Data] = []
    private var finished = false
    init(data: Data) {
        payloads = scanner.push(data)
        scanner.finish()
        finished = true
    }
    func recv() async -> Data? {
        if !payloads.isEmpty { return payloads.removeFirst() }
        return nil
    }
    func lastError() -> RPCError? { scanner.error }
    func trailers() -> Headers { scanner.trailers }
    func cancel() {}
}
