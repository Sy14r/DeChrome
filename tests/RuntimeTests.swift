import Foundation
import Darwin

private struct TestFailure: LocalizedError, CustomStringConvertible {
    let description: String
    var errorDescription: String? { description }
}

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TestFailure(description: message) }
}

@discardableResult
private func command(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    // Drain before waiting, so compiler diagnostics cannot fill a pipe buffer.
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    if process.terminationStatus != 0 {
        throw TestFailure(description: "\(executable) failed (\(process.terminationStatus)): \(text)")
    }
    return text
}

private func expectFailure(_ description: String, _ operation: () throws -> Void) throws {
    do {
        try operation()
    } catch is TestFailure {
        throw TestFailure(description: "\(description): fixture/assertion failed")
    } catch {
        return
    }
    throw TestFailure(description: "\(description): operation unexpectedly succeeded")
}

private final class Fixture {
    let root: URL
    let source: URL
    let resources: URL
    let data: URL
    let logs: URL
    let runtime: DeChromeRuntime
    private let binary: URL
    private let fileManager = FileManager.default

    init(repository: URL, rootDirectory: URL? = nil) throws {
        root = rootDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("DeChromeRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("Source/Google Chrome.app", isDirectory: true)
        resources = root.appendingPathComponent("Resources", isDirectory: true)
        data = root.appendingPathComponent("Data", isDirectory: true)
        logs = root.appendingPathComponent("Logs", isDirectory: true)
        binary = root.appendingPathComponent("fake-chrome")
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
        try command("/usr/bin/xcrun", ["clang", "-target", "arm64-apple-macos13.0", "-Wall", "-Wextra", "-Werror", "-O2", repository.appendingPathComponent("tests/fake-chrome.c").path, "-o", binary.path])
        let librarySource = root.appendingPathComponent("fake-shim.c")
        try "int dechrome_test_fixture(void) { return 1; }\n".write(to: librarySource, atomically: true, encoding: .utf8)
        let library = resources.appendingPathComponent("DeChrome.dylib")
        try command("/usr/bin/xcrun", ["clang", "-target", "arm64-apple-macos13.0", "-dynamiclib", librarySource.path, "-o", library.path])
        try command("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", library.path])
        try "<!doctype html><title>Fake Chrome</title>".write(to: resources.appendingPathComponent("Start.html"), atomically: true, encoding: .utf8)
        runtime = DeChromeRuntime(resourcesURL: resources, dataURL: data, logsURL: logs, sourceChromeURL: source)
        try replaceSource(version: "156.0.0.0")
    }

    func replaceSource(version: String, brokenExecutable: Bool = false) throws {
        if fileManager.fileExists(atPath: source.path) { try fileManager.removeItem(at: source) }
        let executable = source.appendingPathComponent("Contents/MacOS/Google Chrome")
        try fileManager.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: binary, to: executable)
        if brokenExecutable {
            // A truncated Mach-O passes the source's presence/execute checks but
            // must fail code signing inside the staging transaction.
            let header: [UInt8] = [0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1,
                                  0, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0,
                                  32, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
            try Data(header).write(to: executable)
        }
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.google.Chrome",
            "CFBundleName": "Google Chrome",
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "Google Chrome",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": version,
            "LSMinimumSystemVersion": "13.0",
            "KSProductID": "com.google.Chrome",
            "KSVersion": version,
        ]
        let bytes = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try bytes.write(to: source.appendingPathComponent("Contents/Info.plist"))
        if !brokenExecutable {
            try command("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", source.path])
        }
    }

    func cleanup() {
        try? runtime.stop()
        try? fileManager.removeItem(at: root)
    }
}

@main
private struct RuntimeTests {
    static func main() {
        do { try runTests() }
        catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func runTests() throws {
        let repository = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath, isDirectory: true)
        let fixture = try Fixture(repository: repository)
        defer { fixture.cleanup() }
        var passed = 0
        func test(_ name: String, _ body: () throws -> Void) throws {
            try body()
            passed += 1
            print("PASS \(name)")
            fflush(stdout)
        }

        try test("fresh preparation creates a private signed copy") {
            let result = try fixture.runtime.prepare()
            try require(result.changed, "Fresh preparation did not report a change")
            try require(result.version == "156.0.0.0", "Fresh version differs")
            try require(FileManager.default.fileExists(atPath: fixture.runtime.paths.browserApp.path), "Private app missing")
            try command("/usr/bin/codesign", ["--verify", "--strict", fixture.runtime.paths.browserApp.appendingPathComponent("Contents/MacOS/Google Chrome").path])
            let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: fixture.runtime.paths.browserApp.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
            try require(info?["KSProductID"] == nil, "Copied Chrome would still register with Google updater")
            let sourceInfo = try PropertyListSerialization.propertyList(from: Data(contentsOf: fixture.source.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
            try require(sourceInfo?["KSProductID"] != nil, "Source Chrome metadata was altered")
        }

        try test("unchanged version is idempotent") {
            let before = try Data(contentsOf: fixture.runtime.paths.metadataURL)
            let result = try fixture.runtime.prepare()
            try require(!result.changed, "Unchanged source unnecessarily prepared a new copy")
            try require(try Data(contentsOf: fixture.runtime.paths.metadataURL) == before, "Idempotent prepare rewrote metadata")
        }

        let sentinel = fixture.runtime.paths.profileURL.appendingPathComponent("user-data-sentinel.txt")
        try FileManager.default.createDirectory(at: sentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "profile must survive".write(to: sentinel, atomically: true, encoding: .utf8)

        try test("source update refreshes the copy and preserves its profile") {
            try fixture.replaceSource(version: "157.0.0.0")
            let result = try fixture.runtime.prepare()
            try require(result.changed && result.version == "157.0.0.0", "Source upgrade did not refresh")
            try require(result.previousVersion == "156.0.0.0", "Previous version not retained")
            try require(try String(contentsOf: sentinel) == "profile must survive", "Refresh changed user data")
            try require(FileManager.default.fileExists(atPath: fixture.runtime.paths.previousRoot.appendingPathComponent("Google Chrome.app").path), "Previous app backup missing")
        }

        try test("failed refresh leaves the good copy and metadata intact") {
            let before = try Data(contentsOf: fixture.runtime.paths.metadataURL)
            try fixture.replaceSource(version: "158.0.0.0", brokenExecutable: true)
            try expectFailure("Invalid source must fail") { _ = try fixture.runtime.prepare(force: true) }
            try require(try Data(contentsOf: fixture.runtime.paths.metadataURL) == before, "Failed refresh replaced metadata")
            try command("/usr/bin/codesign", ["--verify", "--strict", fixture.runtime.paths.browserApp.appendingPathComponent("Contents/MacOS/Google Chrome").path])
            try require(try String(contentsOf: sentinel) == "profile must survive", "Failed refresh altered profile")
            try fixture.replaceSource(version: "157.0.0.0")
        }

        try test("operation lock rejects concurrent preparation") {
            let descriptor = open(fixture.runtime.paths.lockURL.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
            try require(descriptor >= 0, "Could not open lock fixture")
            defer { flock(descriptor, LOCK_UN); close(descriptor) }
            try require(flock(descriptor, LOCK_EX | LOCK_NB) == 0, "Could not hold fixture lock")
            try expectFailure("Concurrent preparation must be refused") { _ = try fixture.runtime.prepare(force: true) }
        }

        try test("interrupted browser swap recovers its last complete copy") {
            let paths = fixture.runtime.paths
            let metadata = try Data(contentsOf: paths.metadataURL)
            let retainedBackup = fixture.root.appendingPathComponent("Retained.previous")
            try FileManager.default.moveItem(at: paths.previousRoot, to: retainedBackup)
            // Model interruption after current -> previous and before a staged
            // replacement becomes current. The real profile remains external.
            try FileManager.default.moveItem(at: paths.browserRoot, to: paths.previousRoot)
            let result = try fixture.runtime.prepare()
            try require(!result.changed && result.version == "157.0.0.0", "Interrupted swap did not reuse the recovered browser")
            try require(try Data(contentsOf: paths.metadataURL) == metadata, "Recovered metadata changed")
            try require(try String(contentsOf: sentinel) == "profile must survive", "Swap recovery changed user data")
            try command("/usr/bin/codesign", ["--verify", "--strict", paths.browserApp.appendingPathComponent("Contents/MacOS/Google Chrome").path])
            try FileManager.default.moveItem(at: retainedBackup, to: paths.previousRoot)
        }

        try test("running managed process prevents refreshing its executable") {
            let state = try fixture.runtime.launch(url: "about:blank")
            try require(state.pid > 0, "Fixture launch returned no PID")
            try require(try fixture.runtime.status()?.pid == state.pid, "Managed process identity not recognized")
            try expectFailure("Active browser refresh must be refused") { _ = try fixture.runtime.prepare(force: true) }
        }

        try test("live profile owner is protected when process record and lock are missing") {
            let paths = fixture.runtime.paths
            let savedState = try Data(contentsOf: paths.stateURL)
            let metadata = try Data(contentsOf: paths.metadataURL)
            let singleton = paths.profileURL.appendingPathComponent("SingletonLock")
            let linkTarget = try FileManager.default.destinationOfSymbolicLink(atPath: singleton.path)
            guard let running = try fixture.runtime.status() else { throw TestFailure(description: "No fixture process to protect") }
            try FileManager.default.removeItem(at: paths.stateURL)
            try FileManager.default.removeItem(at: singleton)
            defer {
                try? savedState.write(to: paths.stateURL, options: .atomic)
                try? FileManager.default.createSymbolicLink(atPath: singleton.path, withDestinationPath: linkTarget)
            }
            try expectFailure("Unrecorded live browser refresh must be refused") { _ = try fixture.runtime.prepare(force: true) }
            try expectFailure("Unrecorded live profile must not be reopened") { _ = try fixture.runtime.launch(url: "about:blank") }
            try require(Darwin.kill(running.pid, 0) == 0, "Unrecorded browser was terminated")
            try require(!FileManager.default.fileExists(atPath: paths.stateURL.path), "Refused launch created a new process record")
            try require(try Data(contentsOf: paths.metadataURL) == metadata, "Unrecorded live browser files were refreshed")
            try require(try String(contentsOf: sentinel) == "profile must survive", "Live profile was changed")
        }

        try test("PID mismatch cannot terminate an unrelated process") {
            let savedState = try Data(contentsOf: fixture.runtime.paths.stateURL)
            let unrelated = Process()
            unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
            unrelated.arguments = ["30"]
            try unrelated.run()
            defer {
                if unrelated.isRunning { unrelated.terminate() }
                unrelated.waitUntilExit()
                try? savedState.write(to: fixture.runtime.paths.stateURL, options: .atomic)
            }
            var corrupted = try JSONSerialization.jsonObject(with: savedState) as! [String: Any]
            corrupted["pid"] = unrelated.processIdentifier
            try JSONSerialization.data(withJSONObject: corrupted).write(to: fixture.runtime.paths.stateURL, options: .atomic)
            try? fixture.runtime.stop()
            try require(unrelated.isRunning, "Runtime terminated an unrelated PID")
        }

        try test("stop terminates only the recorded browser") {
            try fixture.runtime.stop()
            try require(try fixture.runtime.status() == nil, "Managed browser is still reported alive")
        }

        try test("filesystem aliases preserve process identity and safe stop") {
            let aliasFixture = try Fixture(repository: repository, rootDirectory:
                URL(fileURLWithPath: "/private/tmp/DeChromeAliasTests-\(UUID().uuidString)", isDirectory: true))
            defer { aliasFixture.cleanup() }
            let launched = try aliasFixture.runtime.launch(url: "about:blank")
            let record = aliasFixture.runtime.paths.stateURL
            var saved = try JSONSerialization.jsonObject(with: Data(contentsOf: record)) as! [String: Any]
            func privateSpelling(_ path: String) -> String {
                path.hasPrefix("/tmp/") ? "/private" + path : path
            }
            func publicSpelling(_ path: String) -> String {
                path.hasPrefix("/private/tmp/") ? String(path.dropFirst("/private".count)) : path
            }
            // Model the initial, pre-creation /private/tmp record even when
            // Foundation canonicalizes later runtime URLs to /tmp.
            saved["executable"] = privateSpelling(launched.executable)
            saved["profile"] = privateSpelling(launched.profile)
            let correctRecord = try JSONSerialization.data(withJSONObject: saved)
            try correctRecord.write(to: record, options: .atomic)
            let reopened = DeChromeRuntime(resourcesURL: aliasFixture.resources,
                dataURL: URL(fileURLWithPath: publicSpelling(aliasFixture.data.path), isDirectory: true),
                logsURL: URL(fileURLWithPath: publicSpelling(aliasFixture.logs.path), isDirectory: true),
                sourceChromeURL: aliasFixture.source)
            try require(try reopened.status()?.pid == launched.pid, "Path aliases lost the running browser identity")

            let unrelatedProfile = aliasFixture.root.appendingPathComponent("UnrelatedProfile", isDirectory: true)
            try FileManager.default.createDirectory(at: unrelatedProfile, withIntermediateDirectories: true)
            var unrelated = saved
            unrelated["profile"] = unrelatedProfile.path
            try JSONSerialization.data(withJSONObject: unrelated).write(to: record, options: .atomic)
            try require(try reopened.status() == nil, "A different profile directory was accepted as an alias")
            try reopened.stop()
            try require(Darwin.kill(launched.pid, 0) == 0, "An invalid profile record terminated the browser")
            try correctRecord.write(to: record, options: .atomic)

            try reopened.stop()
            try require(try reopened.status() == nil, "Stop using an alias did not terminate the managed browser")
            try require(!FileManager.default.fileExists(atPath: record.path), "Stop using an alias left a live process record")
        }

        try test("unreadable profile version fails closed without opening the profile") {
            let versionFile = fixture.runtime.paths.dataURL.appendingPathComponent("profile-version.json")
            let valid = try Data(contentsOf: versionFile)
            let invalid = Data("{ interrupted version record".utf8)
            try invalid.write(to: versionFile, options: .atomic)
            defer { try? valid.write(to: versionFile, options: .atomic) }
            try expectFailure("Unreadable profile high-water mark must block launch") { _ = try fixture.runtime.launch(url: "about:blank") }
            try require(try fixture.runtime.status() == nil, "Unreadable version record allowed a browser process")
            try require(try Data(contentsOf: versionFile) == invalid, "Unreadable version record was silently reset")
            try require(try String(contentsOf: sentinel) == "profile must survive", "Unreadable version handling changed user data")
            try require(fixture.runtime.doctor().contains { $0.name == "Profile version" && $0.level == "error" }, "Doctor did not report corrupt profile version")
        }

        try test("rollback rejects a browser older than the profile high-water mark") {
            try expectFailure("Profile downgrade rollback must be refused") { try fixture.runtime.rollback() }
            let result = try fixture.runtime.prepare()
            try require(!result.changed && result.version == "157.0.0.0", "Rejected rollback changed the current browser")
            try require(try String(contentsOf: sentinel) == "profile must survive", "Rejected rollback changed user data")
        }

        try test("an older installed Chrome cannot downgrade the private copy") {
            try fixture.replaceSource(version: "156.0.0.0")
            try expectFailure("Source downgrade must be refused") { _ = try fixture.runtime.prepare(force: true) }
            try require(try String(contentsOf: sentinel) == "profile must survive", "Source downgrade changed user data")
        }

        try test("imported profile selection reaches Chrome and a live copy cannot be refreshed") {
            let imported = try Fixture(repository: repository)
            defer { imported.cleanup() }
            let sourceRoot = imported.root.appendingPathComponent("Synthetic Chrome Data", isDirectory: true)
            let sourceProfile = sourceRoot.appendingPathComponent("Profile 2", isDirectory: true)
            try FileManager.default.createDirectory(at: sourceProfile, withIntermediateDirectories: true)
            try "156.0.0.0".write(to: sourceRoot.appendingPathComponent("Last Version"), atomically: true, encoding: .utf8)
            try JSONSerialization.data(withJSONObject: ["profile": ["info_cache": ["Profile 2":
                ["name":"Synthetic Work", "user_name":"work@example.invalid"]], "last_used":"Profile 2"]])
                .write(to: sourceRoot.appendingPathComponent("Local State"))
            try "{\"profile\":{\"name\":\"Synthetic Work\"}}".write(
                to: sourceProfile.appendingPathComponent("Preferences"), atomically: true, encoding: .utf8)
            let importer = DCProfileImporter(destinationRoot: imported.runtime.paths.profileURL,
                metadataURL: imported.data.appendingPathComponent("imported-profile.json"),
                sourceRoot: sourceRoot, quiescenceCheck: { _ in })
            _ = try importer.importProfile(directory: "Profile 2", expectedBrowserVersion: "156.0.0.0")
            let running = try imported.runtime.launch(url: "about:blank", tabs: true)
            let arguments = try command("/bin/ps", ["-ww", "-p", String(running.pid), "-o", "command="])
            try require(arguments.contains("--profile-directory=Profile 2"), "Chrome opened the default profile instead of the imported profile")
            try require(arguments.contains("--user-data-dir=\(imported.runtime.paths.profileURL.path)"), "Chrome opened the original source profile")
            let before = try Data(contentsOf: imported.runtime.paths.profileURL.appendingPathComponent("Profile 2/Preferences"))
            try expectFailure("A running DeChrome profile cannot be replaced") { _ = try imported.runtime.refreshChromeProfile() }
            try require(try Data(contentsOf: imported.runtime.paths.profileURL.appendingPathComponent("Profile 2/Preferences")) == before,
                        "Rejected refresh changed the live imported profile")
            try imported.runtime.stop()
            try expectFailure("An outdated profile-manager confirmation cannot update a different snapshot") {
                _ = try imported.runtime.refreshChromeProfile(expectedSnapshotID: "outdated-snapshot")
            }
            try require(try Data(contentsOf: imported.runtime.paths.profileURL.appendingPathComponent("Profile 2/Preferences")) == before,
                        "Outdated profile confirmation changed the imported copy")
        }

        print("\(passed) runtime integration tests passed. Fixtures were headless fake Chrome processes only.")
    }
}
