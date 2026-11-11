import XCTest
@testable import HandoffCore

// Expected strings were produced by Node 22's JSON.stringify and path module: the JSON and paths the engine
// writes must match what Claude Desktop and Claude Code produce, byte for byte.
final class RuntimeTests: XCTestCase {
    func testNumberToString() {
        let cases: [Double] = [0, -0.0, 1, -1, 0.1, 1e21, 1e-7, 123456789012345680000, 1.5e-7, 5e-324, 1.7976931348623157e308, 0.000001, 1234.5678, 9007199254740992, 100, 1e20, -1e-6]
        let node = ["0", "0", "1", "-1", "0.1", "1e+21", "1e-7", "123456789012345680000", "1.5e-7", "5e-324", "1.7976931348623157e+308", "0.000001", "1234.5678", "9007199254740992", "100", "100000000000000000000", "-0.000001"]
        XCTAssertEqual(cases.map(numberString), node)
    }

    func testObjectKeyOrderAndOmission() throws {
        let o: Value = ["b": 1, "a": 2, "10": 3, "2": 4, "01": 5, "x": .undefined, "f": Value { _ in .null }]
        XCTAssertEqual(JSON.text(o), #"{"2":4,"10":3,"b":1,"a":2,"01":5}"#)
        let a: Value = [.undefined, Value { _ in .null }, .number(.nan), .number(.infinity)]
        XCTAssertEqual(JSON.text(a), "[null,null,null,null]")
        XCTAssertNil(try JSON.stringify(.undefined))
    }

    func testIndentation() {
        let v: Value = ["a": [1, Value.newObject()], "b": Value.newObject(), "c": Value.newArray()]
        XCTAssertEqual(JSON.text(v, space: 2), "{\n  \"a\": [\n    1,\n    {}\n  ],\n  \"b\": {},\n  \"c\": []\n}")
    }

    func testStringEscapes() {
        XCTAssertEqual(JSON.quote("q\"\\\n\t\u{1}é😀"), "\"q\\\"\\\\\\n\\t\\u0001é😀\"")
    }

    func testParseRoundTripKeepsOrderAndDuplicates() throws {
        let v = try JSON.parse(#"{"z":1,"a":{"y":[1,2.5,-0,1e3]},"z":2,"s":"😀\n"}"#)
        XCTAssertEqual(JSON.text(v), #"{"z":2,"a":{"y":[1,2.5,0,1000]},"s":"😀\n"}"#)
        XCTAssertThrowsError(try JSON.parse("{\"a\":1,}"))
        XCTAssertThrowsError(try JSON.parse(""))
    }

    func testStableSortsKeysByUTF16() {
        let v: Value = ["b": ["d": 1, "c": 2], "a": [["z": 1, "y": 2]], "B": 0]
        XCTAssertEqual(stable(v), #"{"B":0,"a":[{"y":2,"z":1}],"b":{"c":2,"d":1}}"#)
    }

    func testReferenceSemantics() {
        let receipt: Value = ["checks": [["status": "open"]]]
        let check = receipt.checks[0]
        check.status = "cancelled"
        XCTAssertEqual(receipt.checks[0].status, "cancelled")
        receipt.checks.push(["status": "new"])
        XCTAssertEqual(receipt.checks.length, 2)
    }

    func testSpreadAndErrors() {
        let base: Value = ["a": 1, "b": 2]
        XCTAssertEqual(JSON.text(.spread(base, ["a": 3, "c": 4])), #"{"a":3,"b":2,"c":4}"#)
        let e = makeError("boom", code: "X", [("file", "f")])
        XCTAssertEqual(JSON.text(e.value), #"{"code":"X","file":"f"}"#)
        XCTAssertEqual(e.value.description, "Error: boom")
        XCTAssertEqual(e.value.message, "boom")
    }

    func testSetsAndMaps() {
        let s = Value.newSet(["a", "b", "a"])
        XCTAssertEqual(s.length, 2)
        XCTAssertTrue(s.has("a"))
        s.delete("a")
        XCTAssertEqual(s.elements, ["b"])
        let m = Value.newMap()
        m.put("k", 1)
        XCTAssertEqual(m.get("k"), 1)
        XCTAssertEqual(JSON.text(s), "{}")
    }

    func testPath() {
        XCTAssertEqual(
            [path.join("/a/b", "../c/", "./d"), path.join("a", "", "b/"), path.join(""), path.dirname("/a/b/"), path.dirname("a"), path.dirname("/a"),
             path.basename("/a/b.json", ".json"), path.basename("/a/b/"), path.relative("/a/b/c", "/a/d"), path.resolve("/a", "b", "../c/"),
             path.extname("x.tar.gz"), path.normalize("/a//b/../c/.")],
            ["/a/c/d", "a/b/", ".", "/a", ".", "/", "b", "b", "../../d", "/a/c", ".gz", "/a/c"])
    }

    func testLocaleCountAndDates() {
        XCTAssertEqual(count(1234567.891), "1,234,567.891")
        XCTAssertEqual(count(0.5), "0.5")
        XCTAssertEqual(count(1000), "1,000")
        XCTAssertEqual(isoString(dateParse("2026-09-01T00:00:00.123Z")), "2026-09-01T00:00:00.123Z")
        XCTAssertEqual(dateParse("2026-09-01"), 1788220800000)
        XCTAssertEqual(dateParse("2026-09-01T00:00:00+02:00"), 1788213600000)
        XCTAssertTrue(dateParse("nope").isNaN)
    }

    func testRegex() {
        XCTAssertTrue(UUID.test("00000000-0000-4000-8000-000000000001"))
        XCTAssertEqual(UUIDS.matches("a 00000000-0000-4000-8000-000000000001 b 00000000-0000-4000-8000-000000000002").count, 2)
        XCTAssertEqual(re("[:.]", "g").replace("12:34.5", "-"), "12-34-5")
    }

    // identity is stored in caches and receipts: it must stay the dev:ino:size:mtimeNs:ctimeNs join of the stat's fields.
    func testFileStatIdentity() throws {
        let file = NSTemporaryDirectory() + "stat-\(randomUUID())"
        try Data("x".utf8).write(to: URL(fileURLWithPath: file))
        defer { try? FileManager.default.removeItem(atPath: file) }
        for bigint in [true, false] {
            let stat = try FileSystem.nativeStat(file, bigint, follow: true), value = stat.value
            let joined = Value([value["dev"], value["ino"], value["size"], value["mtimeNs"], value["ctimeNs"]]).join(":")
            XCTAssertEqual(stat.identity, joined)
            XCTAssertEqual(stat.isFile, try value["isFile"].call().truthy)
            XCTAssertFalse(stat.isDirectory)
            XCTAssertTrue(stat.sizeValue === value["size"] && stat.mtimeMs === value["mtimeMs"] && stat.inoValue === value["ino"])
        }
    }
}
