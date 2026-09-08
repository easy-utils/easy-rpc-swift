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

public func frame(_ payload: Data, end: Bool = false) -> Data {
    var out = Data([end ? kEndStream : 0])
    withUnsafeBytes(of: UInt32(payload.count).bigEndian) { out.append(contentsOf: $0) }
    out.append(payload)
    return out
}

/// De-frames a server-stream byte stream into payloads.
public struct FrameReader {
    private var acc = Data()
    public init() {}
    public mutating func push(_ chunk: Data) -> [Data] {
        acc.append(chunk)
        var out: [Data] = []
        while true {
            if acc.count < 5 { break }
            let flags = acc[acc.startIndex]
            let len = Int(withUnsafeBytes(of: UInt32(0)) { _ in
                let raw = acc.subdata(in: acc.startIndex..<acc.startIndex+5)
                return UInt32(bitPattern: 0)
            })
            // read 4-byte len from acc[1..5]
            var lenVal: UInt32 = 0
            withUnsafeMutableBytes(of: &lenVal) { ptr in
                _ = acc.copyBytes(to: ptr.bindMemory(to: UInt8.self), from: acc.startIndex+1..<acc.startIndex+5)
            }
            let length = Int(UInt32(bigEndian: lenVal))
            if acc.count < 5 + length { break }
            let payload = acc.subdata(in: acc.startIndex+5..<acc.startIndex+5+length)
            acc.removeFirst(5 + length)
            out.append(payload)
            if (flags & kEndStream) != 0 { break }
        }
        return out
    }
}

/// Protocol-agnostic server-stream.
public protocol Stream: Sendable {
    func recv() async -> Data?
    func cancel()
}

/// Core interface a bridge implements.
public protocol Transport: Sendable {
    func send(_ req: Request) async throws -> Response
    func openStream(_ req: Request) async throws -> any Stream
}

