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
        r.httpMethod = req.method
        r.httpBody = req.body
        r.setValue("application/proto", forHTTPHeaderField: "content-type")
        for (k, vs) in req.headers { for v in vs { r.setValue(v, forHTTPHeaderField: k) } }
        let (data, resp) = try await session.data(for: r)
        let http = resp as! HTTPURLResponse
        let s = http.statusCode
        return Response(status: s, headers: http.allHeaderFields as? [String: [String]] ?? [:], body: data,
                        error: s >= 300 ? rpcError(status: s, headers: http.allHeaderFields, body: data) : nil)
    }

    public func openStream(_ req: Request) async throws -> any Stream {
        var r = URLRequest(url: URL(string: _url(req.url))!)
        r.httpMethod = req.method
        r.httpBody = req.body
        r.setValue("application/connect+proto", forHTTPHeaderField: "content-type")
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

    /// Reconstruct the exact RPCError from connect-code/connect-error.
    private func rpcError(status: Int, headers: [AnyHashable: Any], body: Data) -> RPCError {
        if let c = headers["connect-code"] as? String, let code = Int(c) {
            return RPCError(code: code, message: headers["connect-error"] as? String ?? "")
        }
        return RPCError(code: connectFromStatus(status), message: String(data: body, encoding: .utf8) ?? "")
    }
}

/// Streams from an in-memory byte buffer by de-framing.
private final class BufferedStream: Stream, @unchecked Sendable {
    private var acc: Data
    private var off = 0
    private var err: RPCError?
    init(data: Data) { self.acc = data }
    func recv() async -> Data? {
        // de-frame one message at a time
        while off + 5 <= acc.count {
            let flags = acc[acc.startIndex + off]
            var len: UInt32 = 0
            withUnsafeMutableBytes(of: &len) { p in
                _ = acc.copyBytes(to: p.bindMemory(to: UInt8.self), from: acc.startIndex+off+1..<acc.startIndex+off+5)
            }
            let l = Int(UInt32(bigEndian: len))
            if off + 5 + l > acc.count { break }
            let payload = acc.subdata(in: acc.startIndex+off+5..<acc.startIndex+off+5+l)
            off += 5 + l
            if (flags & kEndStream) != 0 {
                let (code, message) = decodeEndStream(payload)
                if code != 0 { self.err = RPCError(code: code, message: message) }
                return nil
            }
            return payload
        }
        return nil
    }
    func lastError() -> RPCError? { err }
    func cancel() {}
}
