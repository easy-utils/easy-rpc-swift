// AsyncHTTPClient bridge for Linux / server-to-server RPC using swift-server's
// async-http-client (which wraps swift-nio). Covers HTTP/1 + HTTP/2 (h2, h2c).
// No HTTP/3 — on Apple platforms use URLSessionTransport (system-level h3).
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import AsyncHTTPClient
import NIOCore
import NIOHTTP1

public struct AsyncHTTPClientTransport: Transport, Sendable {
    public var base: String
    private let client: HTTPClient

    public init(base: String = "", client: HTTPClient) {
        self.base = base
        self.client = client
    }

    public init(base: String = "") {
        self.base = base
        self.client = HTTPClient(eventLoopGroupProvider: .createNew)
    }

    public func send(_ req: Request) async throws -> Response {
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: "application/proto")
        for (k, vs) in req.headers {
            for v in vs { headers.add(name: k, value: v) }
        }
        var r = HTTPClientRequest(url: _url(req.url))
        r.method = .POST
        r.headers = headers
        if let b = req.body { r.body = .bytes(ByteBuffer(bytes: [UInt8](b))) }
        let resp = try await client.execute(r, timeout: .seconds(30))
        var collected = try await resp.body.collect(upTo: 4 * 1024 * 1024);
        let bytes = collected.readBytes(length: collected.readableBytes) ?? []
        let s = Int(resp.status.code)
        let hdrs = Dictionary(uniqueKeysWithValues: resp.headers.map { ($0.name.lowercased(), [$0.value]) })
        return Response(status: s, headers: hdrs, body: Data(bytes),
                        error: s >= 300 ? rpcError(status: s, headers: resp.headers, body: Data(bytes)) : nil)
    }

    /// Reconstruct the exact RPCError from connect-code/connect-error headers.
    private func rpcError(status: Int, headers: HTTPHeaders, body: Data) -> RPCError {
        if let c = headers.first(name: "connect-code"), let code = Int(c) {
            return RPCError(code: code, message: headers.first(name: "connect-error") ?? "")
        }
        return RPCError(code: connectFromStatus(status), message: String(data: body, encoding: .utf8) ?? "")
    }

    public func openStream(_ req: Request) async throws -> any Stream {
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: "application/connect+proto")
        for (k, vs) in req.headers {
            for v in vs { headers.add(name: k, value: v) }
        }
        var r = HTTPClientRequest(url: _url(req.url))
        r.method = .POST
        r.headers = headers
        if let b = req.body { r.body = .bytes(ByteBuffer(bytes: [UInt8](b))) }
        let resp = try await client.execute(r, timeout: .seconds(30))
        let s = Int(resp.status.code)
        if s >= 300 { throw rpcError(status: s, headers: resp.headers, body: Data()) }
        var collected = try await resp.body.collect(upTo: 4 * 1024 * 1024);
        let bytes = collected.readBytes(length: collected.readableBytes) ?? []
        return BufferedStream(data: Data(bytes))
    }

    public func shutdown() async throws {
        try await client.shutdown()
    }

    @inline(__always) private func _url(_ u: String) -> String {
        u.hasPrefix("http") ? u : base + u
    }
}

/// Streams from an in-memory byte buffer by de-framing.
private final class BufferedStream: Stream, @unchecked Sendable {
    private var acc: Data
    private var off = 0
    private var err: RPCError?
    init(data: Data) { self.acc = data }
    func recv() async -> Data? {
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
