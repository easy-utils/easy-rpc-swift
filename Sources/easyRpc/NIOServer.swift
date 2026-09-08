// Swift server bridge using swift-nio.
import Foundation
import NIO
import NIOHTTP1
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public typealias SwiftUnaryHandler = (String, Data) throws -> Data
public typealias SwiftStreamHandler = (String, Data, (Data) -> Void) throws -> Void

public final class SwiftServerRegistry {
    public var unary: [String: SwiftUnaryHandler] = [:]
    public var stream: [String: SwiftStreamHandler] = [:]
    public init() {}
}

public struct SwiftMethodSpec {
    public let path: String
    public let name: String
    public let serverStream: Bool
    public init(_ p: String, _ n: String, _ ss: Bool) { path = p; name = n; serverStream = ss }
}

public final class SwiftServer {
    private let specs: [SwiftMethodSpec]
    private let reg: SwiftServerRegistry
    public init(specs: [SwiftMethodSpec], reg: SwiftServerRegistry) { self.specs = specs; self.reg = reg }

    public func start(port: Int = 18888) throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(HTTPRequestHandler(specs: self.specs, reg: self.reg))
                                }
            .bind(host: "127.0.0.1", port: port)
        try channel.wait()
    }

    private final class HTTPRequestHandler: ChannelInboundHandler {
        typealias InboundIn = HTTPServerRequestPart
        private let specs: [SwiftMethodSpec]
        private let reg: SwiftServerRegistry
        private var req = HTTPRequestHead(version: .init(major: 1, minor: 1), method: .GET, uri: "")
        private var body = Data()
        init(specs: [SwiftMethodSpec], reg: SwiftServerRegistry) { self.specs = specs; self.reg = reg }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let part = self.unwrapInboundIn(data)
            switch part {
            case .head(let h): self.req = h
            case .body(var b):
                if let d = b.readBytes(length: b.readableBytes) { self.body.append(Data(d)) }
            case .end:
                handle(context: context)
            }
        }
        private func handle(context: ChannelHandlerContext) {
            let path = self.req.uri.components(separatedBy: "?").first ?? ""
            guard let spec = self.specs.first(where: { $0.path == path }) else {
                let h = "404 Not Found"
                let head = HTTPResponseHead(version: self.req.version, status: .notFound, headers: HTTPHeaders([("content-length", "\(h.utf8.count)")]))
                context.write(NIOAny(HTTPServerResponsePart.head(head))).whenComplete { _ in context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))) }
                return
            }
            let kind = (self.req.headers.first(name: "content-type") ?? "").hasPrefix("application/json") ? "json" : "proto"
            let cType = spec.serverStream ? (kind == "json" ? "application/connect+json" : "application/connect+proto") : (kind == "json" ? "application/json" : "application/proto")
            let head = HTTPResponseHead(version: self.req.version, status: .ok, headers: HTTPHeaders([("content-type", cType)]))
            if spec.serverStream {
                let h = self.reg.stream[spec.name]
                if let h = h {
                    do {
                        var frames = Data()
                        try h(kind, self.body) { p in frames.append(SwiftRaw.frame(p)) }
                        let head2 = HTTPResponseHead(version: self.req.version, status: .ok, headers: HTTPHeaders([("content-type", cType), ("content-length", "\(frames.count)")]))
                        var buf = context.channel.allocator.buffer(capacity: frames.count)
                        buf.writeBytes(frames)
                        context.write(NIOAny(HTTPServerResponsePart.head(head2)))
                        context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buf))))
                        context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)))
                    } catch { context.close() }
                } else { context.close() }
            } else {
                let h = self.reg.unary[spec.name]
                if let h = h {
                    do {
                        let out = try h(kind, self.body)
                        var buf = context.channel.allocator.buffer(capacity: out.count)
                        buf.writeBytes(out)
                        let head2 = HTTPResponseHead(version: self.req.version, status: .ok, headers: HTTPHeaders([("content-type", cType), ("content-length", "\(out.count)")]))
                        context.write(NIOAny(HTTPServerResponsePart.head(head2)))
                        context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buf))))
                        context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)))
                    } catch { context.close() }
                } else { context.close() }
            }
        }
    }
}

enum SwiftRaw {
    static func frame(_ payload: Data) -> Data {
        var d = Data([0])
        d.append(UInt32(payload.count).bigEndianBytes)
        d.append(payload)
        return d
    }
}

private extension UInt32 {
    var bigEndianBytes: Data {
        var v = self.bigEndian
        return Data(bytes: &v, count: 4)
    }
}
