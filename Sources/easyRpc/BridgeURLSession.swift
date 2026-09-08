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
        let (data, resp) = try await session.data(for: r)
        let s = (resp as! HTTPURLResponse).statusCode
        return Response(status: s, headers: [:], body: data,
                        error: s >= 300 ? RPCError(code: connectFromStatus(s), message: String(data: data, encoding: .utf8) ?? "") : nil)
    }

    public func openStream(_ req: Request) async throws -> any Stream {
        var r = URLRequest(url: URL(string: _url(req.url))!)
        r.httpMethod = req.method
        r.httpBody = req.body
        r.setValue("application/connect+proto", forHTTPHeaderField: "content-type")
        let (full, resp) = try await session.data(for: r)
        let s = (resp as! HTTPURLResponse).statusCode
        if s >= 300 { throw RPCError(code: connectFromStatus(s), message: "http \(s)") }
        // Linux URLSession lacks bytes(for:); use the full body (Go server sends
        // a complete frame stream in one response). De-frame it here.
        return BufferedStream(data: full)
    }
}

/// Streams from an in-memory byte buffer by de-framing.
private final class BufferedStream: Stream, @unchecked Sendable {
    private var acc: Data
    private var off = 0
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
            if (flags & kEndStream) != 0 { return nil }
            return payload
        }
        return nil
    }
    func cancel() {}
}
