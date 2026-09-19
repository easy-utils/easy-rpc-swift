import Foundation
import easyRpc
import XCTest

// Transport-independent JSON codec tests (proto3 JSON).
final class JsonCodecTests: XCTestCase {
    func testContentKindMapping() {
        XCTAssertEqual(contentKindOf("application/proto"), "proto")
        XCTAssertEqual(contentKindOf("application/json; charset=utf-8"), "json")
        XCTAssertEqual(contentKindOf("application/connect+json"), "json")
        XCTAssertNil(contentKindOf("text/plain"))
        XCTAssertEqual(contentTypeFor(false, "json"), "application/json")
        XCTAssertEqual(contentTypeFor(true, "json"), "application/connect+json")
    }

    func testJsonStringRoundTrip() throws {
        let m = Easyrpc_Conformance_V1_EchoResponse.with { $0.output = "echo:hi" }
        let bytes = try encodeMsg(m, "json")
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.contains("\"output\""), text)
        XCTAssertTrue(text.contains("echo:hi"), text)
        let back = try decodeMsg(bytes, Easyrpc_Conformance_V1_EchoResponse.self, "json")
        XCTAssertEqual(back.output, "echo:hi")
    }

    func testJsonBytesAreBase64() throws {
        let m = Easyrpc_Conformance_V1_EchoBytesResponse.with { $0.data = Data([0, 1, 2, 0xff, 0xfe, 0x80]) }
        let bytes = try encodeMsg(m, "json")
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("AAEC"))
        let back = try decodeMsg(bytes, Easyrpc_Conformance_V1_EchoBytesResponse.self, "json")
        XCTAssertEqual(back.data, m.data)
    }

    func testJsonIgnoresUnknownFields() throws {
        let json = Data("{\"count\":42,\"unknownField\":\"x\"}".utf8)
        let m = try decodeMsg(json, Easyrpc_Conformance_V1_CountRequest.self, "json")
        XCTAssertEqual(m.count, 42)
    }
}
