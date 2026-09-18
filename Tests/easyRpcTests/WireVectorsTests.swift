// Wire golden-vector conformance (transport-independent): the protocol layer
// must reproduce easy-rpc-spec/conformance/wire-vectors.json. Frames are
// byte-exact; JSON payloads compare SEMANTICALLY (key order is not significant).
import XCTest
@testable import easyRpc

final class WireVectorsTests: XCTestCase {
    private func vectors() throws -> [String: Any] {
        let url = Bundle.module.url(forResource: "wire-vectors", withExtension: "json")!
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private func hex(_ b: Data) -> String { b.map { String(format: "%02x", $0) }.joined() }
    private func unhex(_ s: String) -> Data {
        var d = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            d.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return d
    }
    private func canon(_ d: Data) -> String {
        let o = try? JSONSerialization.jsonObject(with: d)
        let out = try? JSONSerialization.data(withJSONObject: o as Any, options: [.sortedKeys])
        return String(data: out ?? Data(), encoding: .utf8) ?? ""
    }
    private func canonStr(_ s: String) -> String { canon(s.data(using: .utf8)!) }
    private func headers(_ any: Any) -> Headers {
        var h: Headers = [:]
        if let obj = any as? [String: [String]] { h = obj }
        return h
    }

    func testFrames() throws {
        for f in try vectors()["frames"] as! [[String: Any]] {
            let e = f["encode"] as! [String: Any]
            var raw = frame(unhex(e["payloadHex"] as! String), end: e["end"] as! Bool)
            if e["compressed"] as! Bool { raw[raw.startIndex] |= 0x01 }
            XCTAssertEqual(hex(raw), f["bytesHex"] as! String, f["name"] as! String)
        }
    }

    func testEndStream() throws {
        for m in try vectors()["endStream"] as! [[String: Any]] {
            let dec = m["decode"] as! [String: Any]
            let es = decodeEndStream(unhex(dec["bytesHex"] as! String))
            XCTAssertEqual(es.code, m["code"] as! Int, "\(m["name"]!) code")
            XCTAssertEqual(es.message, m["message"] as! String, "\(m["name"]!) message")
            if let md = m["metadata"], !(md is NSNull) {
                XCTAssertEqual(es.metadata, headers(md), "\(m["name"]!) metadata")
            }
            if let enc = m["encode"] as? [String: Any], let bh = m["bytesHex"] as? String {
                let md = headers(enc["metadata"] ?? [String: [String]]())
                let got = encodeEndStream(enc["code"] as! Int, enc["message"] as! String, nil, md)
                XCTAssertEqual(canon(got), canon(unhex(bh)), "\(m["name"]!) encode")
            }
        }
    }

    func testUnaryError() throws {
        for u in try vectors()["unaryError"] as! [[String: Any]] {
            let enc = u["encode"] as! [String: Any]
            var details: [ErrorDetail]? = nil
            if let ds = enc["details"] as? [[String: Any]] {
                details = ds.map { ErrorDetail(type: $0["type"] as! String, value: unhex($0["valueHex"] as! String)) }
            }
            let got = encodeErrorJson(enc["code"] as! Int, enc["message"] as! String, details)
            XCTAssertEqual(canon(got), canon(unhex(u["bytesHex"] as! String)), u["name"] as! String)
        }
    }

    func testTrailers() throws {
        for t in try vectors()["trailerHeaders"] as! [[String: Any]] {
            if let demux = t["demux"], !(demux is NSNull) {
                let (h, tl) = demuxTrailers(headers(demux))
                XCTAssertEqual(h, headers(t["headers"]!), "\(t["name"]!) headers")
                XCTAssertEqual(tl, headers(t["trailers"]!), "\(t["name"]!) trailers")
            }
            if let mux = t["mux"] as? [String: Any] {
                let got = muxTrailers(headers(mux["headers"]!), headers(mux["trailers"]!))
                XCTAssertEqual(got, headers(t["result"]!), "\(t["name"]!) mux")
            }
        }
    }

    func testCodeMap() throws {
        for c in try vectors()["codeNames"] as! [[String: Any]] {
            let code = c["code"] as! Int
            let name = c["name"] as! String
            XCTAssertEqual(codeToString(code), name, "code \(code)")
            XCTAssertEqual(codeFromString(name), code, "name \(name)")
            if code != 0 { XCTAssertEqual(httpStatus(code), c["http"] as! Int, "http \(code)") }
        }
    }
}
