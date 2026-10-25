@testable import AtlasCore
import XCTest

final class UpdaterTests: XCTestCase {
    func testVersionOrdering() {
        XCTAssertTrue(Updater.isNewer("1.3.0", than: "1.2.0"))
        XCTAssertTrue(Updater.isNewer("1.10.0", than: "1.9.2"))
        XCTAssertTrue(Updater.isNewer("2", than: "1.99.99"))
        XCTAssertFalse(Updater.isNewer("1.2.0", than: "1.2.0"))
        XCTAssertFalse(Updater.isNewer("1.2", than: "1.2.0"))
        XCTAssertFalse(Updater.isNewer("1.1.9", than: "1.2.0"))
    }

    /// Set ATLAS_TEST_DMG to a release disk image (scripts/package-release.sh) to exercise staging.
    private func dmgOrSkip() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["ATLAS_TEST_DMG"] else { throw XCTSkip("ATLAS_TEST_DMG not set") }
        return URL(fileURLWithPath: path)
    }

    private func fakeInstall() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-upd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("ATLAS.app"), withIntermediateDirectories: true)
        return dir.appendingPathComponent("ATLAS.app")
    }

    func testStagesAVerifiedRelease() async throws {
        let dmg = try dmgOrSkip()
        let app = try fakeInstall()
        let r = Updater.Release(version: "9.9.9", notes: "", dmg: dmg, checksum: URL(fileURLWithPath: dmg.path + ".sha256"), page: dmg)
        let staged = try await Updater.stage(r, replacing: app) { _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.appendingPathComponent("Contents/MacOS/ATLAS").path))
    }

    func testRejectsAChecksumMismatch() async throws {
        let dmg = try dmgOrSkip()
        let app = try fakeInstall()
        let bad = app.deletingLastPathComponent().appendingPathComponent("bad.sha256")
        try String(repeating: "0", count: 64).write(to: bad, atomically: true, encoding: .utf8)
        let r = Updater.Release(version: "9.9.9", notes: "", dmg: dmg, checksum: bad, page: dmg)
        do { _ = try await Updater.stage(r, replacing: app) { _ in }; XCTFail("accepted a bad checksum") } catch {
            XCTAssertTrue(error.localizedDescription.contains("checksum"))
        }
    }

    /// An image whose app is ad-hoc signed (not the ATLAS Release certificate) must be refused.
    func testRejectsAnUnpinnedSignature() async throws {
        let dmg = try dmgOrSkip()
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-forge-\(UUID().uuidString)")
        let src = work.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let mnt = work.appendingPathComponent("mnt")
        try shell("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mnt.path])
        try shell("/usr/bin/ditto", [mnt.appendingPathComponent("ATLAS.app").path, src.appendingPathComponent("ATLAS.app").path])
        try shell("/usr/bin/hdiutil", ["detach", mnt.path, "-force"])
        try shell("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", src.appendingPathComponent("ATLAS.app").path])
        let forged = work.appendingPathComponent("forged.dmg")
        try shell("/usr/bin/hdiutil", ["create", "-srcfolder", src.path, "-format", "UDZO", forged.path])
        let sum = work.appendingPathComponent("forged.dmg.sha256")
        try shell("/bin/sh", ["-c", "shasum -a 256 \"$0\" | cut -d' ' -f1 > \"$1\"", forged.path, sum.path])
        let app = try fakeInstall()
        let r = Updater.Release(version: "9.9.9", notes: "", dmg: forged, checksum: sum, page: forged)
        do { _ = try await Updater.stage(r, replacing: app) { _ in }; XCTFail("accepted an ad-hoc signed app") } catch {
            XCTAssertTrue(error.localizedDescription.contains("certificate"))
        }
    }

    private func shell(_ exe: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 { throw NSError(domain: "shell", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "\(exe) \(args) failed"]) }
    }
}
