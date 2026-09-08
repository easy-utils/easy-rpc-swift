import Foundation
import easyRpc
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class InteropTests: XCTestCase {
    func testEchoUnary() async throws {
        let t = URLSessionTransport(base: "http://127.0.0.1:18888")
        let c = ConformanceServiceClient(t)
        let out = try await c.echo(req: Easyrpc_Conformance_V1_EchoRequest.with { $0.input = "hi" })
        XCTAssertEqual(out.output, "echo:hi")
    }
    func testCountStream() async throws {
        let t = URLSessionTransport(base: "http://127.0.0.1:18888")
        let c = ConformanceServiceClient(t)
        var idx: [Int] = []
        let stream = try await c.count(req: Easyrpc_Conformance_V1_CountRequest.with { $0.count = 3 })
        for try await m in stream { idx.append(Int(m.index)) }
        XCTAssertEqual(idx, [0,1,2])
    }
}
