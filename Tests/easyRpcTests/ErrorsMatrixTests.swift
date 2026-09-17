// Error-path matrix (spec §4.2 M1–M13) + Error Details round-trip (§4.1).
// Mirrored in every language implementation; inputs are constructed directly
// against the protocol functions — no server needed.
import XCTest
@testable import easyRpc

final class ErrorsMatrixTests: XCTestCase {
    let detail = ErrorDetail(type: "type.googleapis.com/google.rpc.RetryInfo",
                             value: Data([1, 2, 3, 250]))

    func enc(_ s: String) -> Data { Data(s.utf8) }

    func testM1EmptyPayloadIsCleanEnd() {
        let (c, m, d) = decodeEndStream(Data())
        XCTAssertEqual(c, 0); XCTAssertEqual(m, ""); XCTAssertNil(d)
    }

    func testM2GarbageIsCleanEnd() {
        let (c, _, _) = decodeEndStream(Data([0xff, 0xfe, 0x00, 0x42]))
        XCTAssertEqual(c, 0)
    }

    func testM3ErrorWithoutCodeIsUnknown() {
        let (c, m, _) = decodeEndStream(enc(#"{"error":{}}"#))
        XCTAssertEqual(c, 2); XCTAssertEqual(m, "")
    }

    func testM4UnknownCodeNameIs2() {
        let (c, m, _) = decodeEndStream(enc(#"{"error":{"code":"nope","message":"m"}}"#))
        XCTAssertEqual(c, 2); XCTAssertEqual(m, "m")
    }

    func testM5UnknownFieldsIgnored() {
        let (c, _, _) = decodeEndStream(enc(#"{"error":{"code":"not_found","message":"m"},"x":1}"#))
        XCTAssertEqual(c, 5)
    }

    func testM6DetailsRoundTrip() {
        let payload = encodeEndStream(8, "rate limited", [detail])
        let (c, m, d) = decodeEndStream(payload)
        XCTAssertEqual(c, 8); XCTAssertEqual(m, "rate limited")
        XCTAssertEqual(d, [detail])
    }

    func testM7MalformedDetailsEntriesSkipped() {
        let json = #"{"error":{"code":"resource_exhausted","details":["# +
            #"{"type":"t","value":"!!!"},{"value":"x"},{"type":"ok"},"# +
            #"{"type":"t2","value":"AQID"}]}}"#
        let (_, _, d) = decodeEndStream(enc(json))
        XCTAssertEqual(d, [ErrorDetail(type: "t2", value: Data([1, 2, 3]))])
    }

    func testDetailsOmittedWhenEmpty() {
        let text = String(data: encodeEndStream(5, "gone"), encoding: .utf8)!
        XCTAssertEqual(text, #"{"error":{"code":"not_found","message":"gone"}}"#)
    }

    func testM11PlainTextIsNotJsonError() {
        let (c, _, _) = decodeErrorJson(enc("busy"))
        XCTAssertEqual(c, 0)
    }

    func testUnaryDetailsRoundTrip() {
        let body = encodeErrorJson(8, "limited", [detail])
        let (c, m, d) = decodeErrorJson(body)
        XCTAssertEqual(c, 8); XCTAssertEqual(m, "limited")
        XCTAssertEqual(d, [detail])
    }

    func testM12M13DeadlineMapsToCode4() {
        let (c, _, _) = decodeErrorJson(encodeErrorJson(4, "deadline exceeded"))
        XCTAssertEqual(c, 4)
        XCTAssertEqual(httpStatus(4), 504)
        XCTAssertEqual(connectFromStatus(504), 4)
    }
}
