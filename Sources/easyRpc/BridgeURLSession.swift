// URLSession bridge (Apple platforms). Wrapped in #if canImport so the core
// library compiles on Linux (parse-level) while providing a real client on
// iOS/macOS.
#if os(macOS) || os(iOS)
import Foundation
import FoundationNetworking

public final class URLSessionTransport: Transport, @unchecked Sendable {
    private let session: URLSession
    convenience public init(base: String = "") { self.init(session: .shared) }
    public init(session: URLSession) { self.session = session }

    public func send(_ req: Request) async throws -> Response {
        var r = URLRequest(url: URL(string: req.url)!)
        r.httpMethod = req.method
        r.httpBody = req.body
        r.setValue("application/proto", forHTTPHeaderField: "content-type")
        let (data, resp) = try await session.data(for: r)
        let s = (resp as! HTTPURLResponse).statusCode
        return Response(status: s, headers: [:], body: data,
                        error: s >= 300 ? RPCError(code: connectFromStatus(s), message: String(data: data, encoding: .utf8) ?? "") : nil)
    }

    public func openStream(_ req: Request) async throws -> any Stream {
        var r = URLRequest(url: URL(string: req.url)!)
        r.httpMethod = req.method
        r.httpBody = req.body
        r.setValue("application/connect+proto", forHTTPHeaderField: "content-type")
        let (bytes, resp) = try await session.bytes(for: r)
        let s = (resp as! HTTPURLResponse).statusCode
        if s >= 300 { throw RPCError(code: connectFromStatus(s), message: "http \(s)") }
        return URLSessionStream(reader: FrameReader(), byteIter: bytes)
    }
}

private final class URLSessionStream: Stream, @unchecked Sendable {
    var reader: FrameReader
    var byteIter: URLSession.AsyncBytes
    init(reader: FrameReader, byteIter: URLSession.AsyncBytes) { self.reader = reader; self.byteIter = byteIter }
    func recv() async -> Data? {
        while true {
            var chunk = Data()
            do { if let b = try await byteIter.next() { chunk.append(b) } else { return nil } }
            catch { return nil }
            let frames = reader.push(chunk)
            if let f = frames.first { return f }
        }
    }
    func cancel() { byteIter.task.cancel() }
}
#endif
