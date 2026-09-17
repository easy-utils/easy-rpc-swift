import Foundation
import easyRpc
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class InteropTests: XCTestCase {
    func testEchoUnary() async throws {
        let base = ProcessInfo.processInfo.environment["EASY_RPC_BASE"] ?? "http://127.0.0.1:18888"
        let t = URLSessionTransport(base: base)
        let c = ConformanceServiceClient(t)
        let out = try await c.echo(req: Easyrpc_Conformance_V1_EchoRequest.with { $0.input = "hi" })
        XCTAssertEqual(out.output, "echo:hi")
    }
    func testCountStream() async throws {
        let base = ProcessInfo.processInfo.environment["EASY_RPC_BASE"] ?? "http://127.0.0.1:18888"
        let t = URLSessionTransport(base: base)
        let c = ConformanceServiceClient(t)
        var idx: [Int] = []
        let stream = try await c.count(req: Easyrpc_Conformance_V1_CountRequest.with { $0.count = 3 })
        for try await m in stream { idx.append(Int(m.index)) }
        XCTAssertEqual(idx, [0,1,2])
    }

    func testFailDetailsUnaryCarriesDetails() async throws {
        let base = ProcessInfo.processInfo.environment["EASY_RPC_BASE"] ?? "http://127.0.0.1:18888"
        let c = ConformanceServiceClient(URLSessionTransport(base: base))
        do {
            _ = try await c.failDetails(req: Easyrpc_Conformance_V1_FailDetailsRequest.with {
                $0.code = 8
                $0.message = "limited"
                $0.detailType = "type.googleapis.com/google.rpc.RetryInfo"
                $0.detailText = "retry:5s"
            })
            XCTFail("expected RPCError")
        } catch let e as RPCError {
            XCTAssertEqual(e.code, 8)
            XCTAssertEqual(e.message, "limited")
            let d = try XCTUnwrap(e.details?.first)
            XCTAssertEqual(d.type, "type.googleapis.com/google.rpc.RetryInfo")
            XCTAssertEqual(String(data: d.value, encoding: .utf8), "retry:5s")
        }
    }

    func testStreamFailDetailsSurfacesDetails() async throws {
        let base = ProcessInfo.processInfo.environment["EASY_RPC_BASE"] ?? "http://127.0.0.1:18888"
        let c = ConformanceServiceClient(URLSessionTransport(base: base))
        let stream = try await c.streamFailDetails(req: Easyrpc_Conformance_V1_StreamFailDetailsRequest.with {
            $0.emitBefore = 2
            $0.code = 13
            $0.message = "boom"
            $0.detailType = "t/stream"
            $0.detailText = "sd"
        })
        var seen: [Int] = []
        do {
            for try await m in stream { seen.append(Int(m.index)) }
            XCTFail("expected RPCError")
        } catch let e as RPCError {
            XCTAssertEqual(seen, [0, 1])
            XCTAssertEqual(e.code, 13)
            let d = try XCTUnwrap(e.details?.first)
            XCTAssertEqual(d.type, "t/stream")
            XCTAssertEqual(String(data: d.value, encoding: .utf8), "sd")
        }
    }

    // ---- AsyncHTTPClient bridge (Linux/server side) ----
    // The locally-testable variant of the Swift bridge family (URLSession is
    // exercised by the tests above; AHC is the Linux/server adapter).
    func testAHCClientAgainstConformanceServer() async throws {
        // AHC's event-loop init crashes in sandboxed macOS containers (the
        // URLSession tests cover the Darwin network stack there); Linux CI
        // covers AHC itself.
        try XCTSkipIf(ProcessInfo.processInfo.environment["EASYRPC_SKIP_AHC"] == "1",
                      "EASYRPC_SKIP_AHC=1 (macOS container)")
        let base = ProcessInfo.processInfo.environment["EASY_RPC_BASE"] ?? "http://127.0.0.1:18888"
        let ahc = AsyncHTTPClientTransport(base: base)
        let t = InterceptorTransport([], ahc)
        let c = ConformanceServiceClient(t)
        let out = try await c.echo(req: Easyrpc_Conformance_V1_EchoRequest.with { $0.input = "hi" })
        XCTAssertEqual(out.output, "echo:hi")

        let stream = try await c.count(req: Easyrpc_Conformance_V1_CountRequest.with { $0.count = 3 })
        var idx: [Int] = []
        for try await m in stream { idx.append(Int(m.index)) }
        XCTAssertEqual(idx, [0, 1, 2])

        do {
            _ = try await c.failDetails(req: Easyrpc_Conformance_V1_FailDetailsRequest.with {
                $0.code = 8
                $0.message = "limited"
                $0.detailType = "type.googleapis.com/google.rpc.RetryInfo"
                $0.detailText = "retry:5s"
            })
            XCTFail("expected RPCError")
        } catch let e as RPCError {
            XCTAssertEqual(e.code, 8)
            let d = try XCTUnwrap(e.details?.first)
            XCTAssertEqual(d.type, "type.googleapis.com/google.rpc.RetryInfo")
            XCTAssertEqual(String(data: d.value, encoding: .utf8), "retry:5s")
        }
        // AHC requires explicit shutdown before deinit (precondition).
        try await ahc.shutdown()
    }
}
