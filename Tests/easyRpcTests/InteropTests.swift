import Foundation
import SwiftProtobuf
import easyRpc
import XCTest

final class InteropTests: XCTestCase {
    func testEchoUnary() async throws {
        let t = URLSessionTransport()
        let req = Request(url: "http://127.0.0.1:18888/v1/echo", body: try Easyrpc_Conformance_V1_EchoRequest.with { $0.input = "hi" }.serializedData())
        let res = try await t.send(req)
        XCTAssertEqual(res.status, 200)
        let out = try Easyrpc_Conformance_V1_EchoResponse(serializedBytes: res.body)
        XCTAssertEqual(out.output, "echo:hi")
    }
}
