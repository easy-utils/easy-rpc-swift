// Fault injection (spec §4.2 M8/M10 + F2) at the protocol level: FrameScanner
// MUST error on truncated/END-less/corrupt-gzip bodies, reassemble frames
// split across chunks, and treat a garbage END payload as a clean end.
import Foundation
import XCTest
@testable import easyRpc

final class FaultInjectionTests: XCTestCase {
    var savedHook: (@Sendable (Data) -> Data?)?

    override func setUp() {
        super.setUp()
        savedHook = gzipDecompressHook
        // A real (strict) decompressor for the tests: valid gzip -> data,
        // anything else -> nil (M10).
        gzipDecompressHook = { data in
            guard data.prefix(2) == Data([0x1f, 0x8b]) else { return nil }
            return Data([7]) // "decompressed" marker
        }
    }

    override func tearDown() {
        gzipDecompressHook = savedHook
        super.tearDown()
    }

    func frame(_ payload: Data, end: Bool = false, compressed: Bool = false) -> Data {
        let flags: UInt8 = (end ? 0x02 : 0) | (compressed ? 0x01 : 0)
        var len = UInt32(payload.count).bigEndian
        var out = Data([flags])
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    func testF1MidFrameTruncation() {
        let s = FrameScanner()
        XCTAssertEqual(s.push(frame(Data([0]))), [Data([0])])
        let full = frame(Data(repeating: 1, count: 8))
        _ = s.push(full.prefix(full.count - 4))
        s.finish()
        XCTAssertEqual(s.error?.code, 13)
    }

    func testF2MissingEndFrame() {
        let s = FrameScanner()
        _ = s.push(frame(Data([0])))
        _ = s.push(frame(Data([1])))
        XCTAssertNil(s.error)
        s.finish()
        XCTAssertEqual(s.error?.code, 13)
    }

    func testF3GarbageEndIsClean() {
        let s = FrameScanner()
        XCTAssertEqual(s.push(frame(Data([0]))), [Data([0])])
        _ = s.push(frame(Data([0xff, 0xfe, 0x42]), end: true))
        s.finish()
        XCTAssertNil(s.error)
    }

    func testF4CorruptGzipErrors() {
        // hook (setUp) treats non-gzip-magic bytes as corrupt
        let s = FrameScanner()
        _ = s.push(frame(Data([0x00, 0x11, 0x22]), compressed: true))
        XCTAssertEqual(s.error?.code, 13)
    }

    func testF5FramesSplitAcrossChunks() {
        let body = frame(Data([0])) + frame(Data([1])) + frame(Data(), end: true)
        let s = FrameScanner()
        var got: [Data] = []
        var i = body.startIndex
        while i < body.endIndex {
            let j = body.index(i, offsetBy: 3, limitedBy: body.endIndex) ?? body.endIndex
            got += s.push(body.subdata(in: i..<j))
            i = j
        }
        s.finish()
        XCTAssertNil(s.error)
        XCTAssertEqual(got, [Data([0]), Data([1])])
    }

    func testF6ValidGzipDecodes() {
        // hook: gzip magic + a single-byte payload marker we can verify
        gzipDecompressHook = { data in
            guard data.prefix(2) == Data([0x1f, 0x8b]) else { return nil }
            return Data([7]) // "decompressed" marker
        }
        let gz = Data([0x1f, 0x8b, 0x08, 0x00]) // valid magic; hook returns the payload
        let s = FrameScanner()
        let got = s.push(frame(gz, compressed: true)) + s.push(frame(Data(), end: true))
        s.finish()
        XCTAssertNil(s.error)
        XCTAssertEqual(got, [Data([7])])
    }
}
