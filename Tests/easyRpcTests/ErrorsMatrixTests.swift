// Error-path matrix (spec §4.2 M1–M16) + Error Details round-trip (§4.1).
// Mirrored in every language implementation; inputs are constructed directly
// against the protocol functions - no server needed.
import XCTest
@testable import easyRpc

final class ErrorsMatrixTests: XCTestCase {
    let detail = ErrorDetail(type: "type.googleapis.com/google.rpc.RetryInfo", value: Data([1, 2, 3, 250]))

    func enc(_ s: String) -> Data { Data(s.utf8) }

    func testM1EmptyPayloadIsCleanEnd() {
        let es = decodeEndStream(Data())
        XCTAssertEqual(es.code, 0); XCTAssertEqual(es.message, ""); XCTAssertNil(es.details)
    }

    func testM2GarbageIsCleanEnd() {
        let es = decodeEndStream(Data([0xff, 0xfe, 0x00, 0x42]))
        XCTAssertEqual(es.code, 0)
    }

    func testM3ErrorWithoutCodeIsUnknown() {
        let es = decodeEndStream(enc(#"{"error":{}}"#))
        XCTAssertEqual(es.code, 2); XCTAssertEqual(es.message, "")
    }

    func testM4UnknownCodeNameIs2() {
        let es = decodeEndStream(enc(#"{"error":{"code":"nope","message":"m"}}"#))
        XCTAssertEqual(es.code, 2); XCTAssertEqual(es.message, "m")
    }

    func testM5UnknownFieldsIgnored() {
        let es = decodeEndStream(enc(#"{"error":{"code":"not_found","message":"m"},"x":1}"#))
        XCTAssertEqual(es.code, 5)
    }

    func testM6DetailsRoundTrip() {
        let es = decodeEndStream(encodeEndStream(8, "rate limited", [detail]))
        XCTAssertEqual(es.code, 8); XCTAssertEqual(es.message, "rate limited")
        XCTAssertEqual(es.details, [detail])
    }

    func testM7MalformedDetailsEntriesSkipped() {
        let json = #"{"error":{"code":"resource_exhausted","details":["# +
            #"{"type":"t","value":"!!!"},{"value":"x"},{"type":"ok"},"# +
            #"{"type":"t2","value":"AQID"}]}}"#
        let es = decodeEndStream(enc(json))
        XCTAssertEqual(es.details, [ErrorDetail(type: "t2", value: Data([1, 2, 3]))])
    }

    func testM14EndMetadataIsTrailers() {
        let es = decodeEndStream(enc(#"{"metadata":{"x-trl":["v1","v2"]}}"#))
        XCTAssertEqual(es.code, 0)
        XCTAssertEqual(es.metadata["x-trl"], ["v1", "v2"])
    }

    func testM15DemuxTrailersPrefixCaseInsensitive() {
        let (h, t) = demuxTrailers(["content-type": ["application/proto"], "Trailer-X-Trl": ["a"]])
        XCTAssertEqual(h["content-type"], ["application/proto"])
        XCTAssertEqual(t["x-trl"], ["a"])
    }

    func testDetailsOmittedWhenEmpty() {
        let text = String(data: encodeEndStream(5, "gone"), encoding: .utf8)!
        XCTAssertEqual(text, #"{"error":{"code":"not_found","message":"gone"}}"#)
    }

    func testCleanEndSerializesAsEmptyObject() {
        // Connect's END frame parser requires valid JSON; a clean end is `{}`.
        let text = String(data: encodeEndStream(0, ""), encoding: .utf8)!
        XCTAssertEqual(text, "{}")
    }

    func testM11PlainTextIsNotJsonError() {
        let (c, _, _) = decodeErrorJson(enc("busy"))
        XCTAssertEqual(c, 0)
    }

    func testUnaryDetailsRoundTrip() {
        let (c, m, d) = decodeErrorJson(encodeErrorJson(8, "limited", [detail]))
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
