import XCTest
@testable import TranscriptCore

final class FileSessionStoreTests: XCTestCase {
    func testSaveLoadListDelete() throws {
        let store = FileSessionStore(rootDirectory: try makeTempDirectory())
        let older = TranscriptSession(localeIdentifier: "en-US", startedAt: t0, items: [speech("hi", 1, 2)])
        let newer = TranscriptSession(localeIdentifier: "zh-CN", startedAt: at(3600))
        try store.save(older)
        try store.save(newer)

        XCTAssertEqual(try store.load(id: older.id), older)
        XCTAssertEqual(try store.listSessions().map(\.id), [newer.id, older.id])

        try store.delete(id: older.id)
        XCTAssertEqual(try store.listSessions().map(\.id), [newer.id])
        XCTAssertThrowsError(try store.load(id: older.id))
        XCTAssertNoThrow(try store.delete(id: older.id), "deleting twice is fine")
    }

    func testOverwriteKeepsLatestVersion() throws {
        let store = FileSessionStore(rootDirectory: try makeTempDirectory())
        var session = TranscriptSession(localeIdentifier: "en-US", startedAt: t0)
        try store.save(session)
        session.insert(speech("more", 1, 2))
        session.title = "Renamed"
        try store.save(session)
        XCTAssertEqual(try store.load(id: session.id), session)
    }

    func testListSkipsCorruptSessions() throws {
        let root = try makeTempDirectory()
        let store = FileSessionStore(rootDirectory: root)
        let good = TranscriptSession(localeIdentifier: "en-US", startedAt: t0)
        try store.save(good)
        let badDirectory = store.sessionDirectory(for: UUID())
        try FileManager.default.createDirectory(at: badDirectory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: badDirectory.appendingPathComponent("session.json"))
        XCTAssertEqual(try store.listSessions().map(\.id), [good.id])
    }

    func testListOnEmptyStore() throws {
        let store = FileSessionStore(rootDirectory: try makeTempDirectory().appendingPathComponent("missing"))
        XCTAssertEqual(try store.listSessions(), [])
    }

    func testWritePhoto() throws {
        let store = FileSessionStore(rootDirectory: try makeTempDirectory())
        let id = UUID()
        let url = try store.writePhoto(Data([1, 2, 3]), sessionID: id, fileName: "a.jpg")
        XCTAssertEqual(url, store.photoURL(sessionID: id, fileName: "a.jpg"))
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3]))
    }
}

final class DiagnosticsLogTests: XCTestCase {
    func testLogsToMemoryAndFile() throws {
        let file = try makeTempDirectory().appendingPathComponent("logs/diag.log")
        let log = DiagnosticsLog(fileURL: file, maxEntries: 2, now: { t0 })
        log.log("one")
        log.log("two", category: "engine")
        log.log("three")
        XCTAssertEqual(log.recentEntries(), ["2026-11-04T14:00:00Z [engine] two", "2026-11-04T14:00:00Z [app] three"])
        XCTAssertEqual(log.exportText().split(separator: "\n").count, 3)
        log.clear()
        XCTAssertEqual(log.recentEntries(), [])
        XCTAssertEqual(log.exportText(), "")
    }

    func testRotatesLargeFile() throws {
        let file = try makeTempDirectory().appendingPathComponent("diag.log")
        let log = DiagnosticsLog(fileURL: file, maxFileBytes: 200)
        for i in 0..<20 { log.log("line number \(i) with some padding text") }
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int ?? 0
        XCTAssertLessThan(size, 400)
        XCTAssertTrue(log.exportText().contains("line number 19"))
    }
}
