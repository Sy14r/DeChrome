import Foundation
import Darwin

private struct ImportTestFailure: Error, CustomStringConvertible {
    let description: String
}
private func expect(_ value: @autoclosure () throws -> Bool, _ text: String) throws {
    if try !value() { throw ImportTestFailure(description: text) }
}
private func fails(_ text: String, _ block: () throws -> Void) throws {
    do { try block() }
    catch is ImportTestFailure { throw ImportTestFailure(description: "\(text): fixture assertion failed") }
    catch { return }
    throw ImportTestFailure(description: "\(text): unexpectedly succeeded")
}

private final class ImportFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeChromeProfileTests-\(UUID().uuidString)", isDirectory: true)
    var source: URL { root.appendingPathComponent("Chrome", isDirectory: true) }
    var destination: URL { root.appendingPathComponent("DeChrome/Profile", isDirectory: true) }
    var metadata: URL { root.appendingPathComponent("DeChrome/imported-profile.json") }
    var previous: URL { destination.appendingPathExtension("previous") }
    var selected: URL { source.appendingPathComponent("Profile 2", isDirectory: true) }
    var importer: DCProfileImporter { make() }
    let fm = FileManager.default

    init() throws {
        try fm.createDirectory(at: source, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try write("old-destination", destination.appendingPathComponent("Existing"))
        try write("156.0.8078.80\n", source.appendingPathComponent("Last Version"))
        let state: [String: Any] = ["profile": ["info_cache": [
            "Default": ["name":"Personal", "user_name":"personal@example.invalid"],
            "Profile 2": ["name":"Work", "user_name":"work@example.invalid"],
            "../outside": ["name":"Unsafe"]], "last_used":"Default"],
            "os_crypt": ["encrypted_key":"synthetic-key"], "unrelated_account_cache":["private":"not-selected"]]
        try json(state, source.appendingPathComponent("Local State"))
        try write("personal-only", source.appendingPathComponent("Default/Bookmarks"))
        try write("work-bookmarks", selected.appendingPathComponent("Bookmarks"))
        try json(["marker":"work-preferences", "extensions":["settings":[
            "cccccccccccccccccccccccccccccccc":["path":"/Library/Example/WorkExtension"]]]],
                 selected.appendingPathComponent("Preferences"))
        try write("sqlite-db", selected.appendingPathComponent("History"))
        try write("committed-wal", selected.appendingPathComponent("History-wal"))
        try write("saved-session", selected.appendingPathComponent("Sessions/Session_1"))
        try write("extension-data", selected.appendingPathComponent("Local Extension Settings/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/000003.log"))
        try write("extension-code", selected.appendingPathComponent("Extensions/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/1.0/manifest.json"))
        try write("real-extension-asset", selected.appendingPathComponent("Extensions/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/1.0/Cache/script.js"))
        try write("real-singleton-asset", selected.appendingPathComponent("Extensions/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/1.0/Singleton.js"))
        try write("cache", selected.appendingPathComponent("Cache/Cache_Data/data_1"))
        try write("code-cache", selected.appendingPathComponent("Code Cache/js/1"))
        try fm.createSymbolicLink(atPath: selected.appendingPathComponent("SingletonLock").path, withDestinationPath: "test-host-99999999")
        try write("stale-port", source.appendingPathComponent("DevToolsActivePort"))
        try json(["name":"native.work", "path":"/Library/Example/native-helper", "type":"stdio",
                  "allowed_origins":["chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/"]],
                 source.appendingPathComponent("NativeMessagingHosts/native.work.json"))
        try json(["name":"native.other", "path":"/Library/Example/other-helper", "type":"stdio",
                  "allowed_origins":["chrome-extension://bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/"]],
                 source.appendingPathComponent("NativeMessagingHosts/native.other.json"))
        try json(["name":"native.external", "path":"/Library/Example/external-helper", "type":"stdio",
                  "allowed_origins":["chrome-extension://cccccccccccccccccccccccccccccccc/"]],
                 source.appendingPathComponent("NativeMessagingHosts/native.external.json"))
    }
    deinit { try? fm.removeItem(at: root) }
    func make(guardCheck: @escaping (URL) throws -> Void = { _ in },
              copier: ((URL, URL) throws -> Void)? = nil) -> DCProfileImporter {
        DCProfileImporter(destinationRoot: destination, metadataURL: metadata, sourceRoot: source,
                          quiescenceCheck: guardCheck, copyFile: copier)
    }
    func write(_ value: String, _ file: URL) throws {
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if file.lastPathComponent == "Preferences", !value.hasPrefix("{") {
            try JSONSerialization.data(withJSONObject: ["marker":value], options: [.sortedKeys]).write(to: file, options: .atomic)
        } else { try value.write(to: file, atomically: true, encoding: .utf8) }
    }
    func json(_ value: Any, _ file: URL) throws {
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: file)
    }
    func text(_ file: URL) throws -> String {
        let value = try String(contentsOf: file, encoding: .utf8)
        if file.lastPathComponent == "Preferences", let marker = (try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])?["marker"] as? String { return marker }
        return value
    }
    func inode(_ file: URL) throws -> UInt64 {
        (try fm.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber)!.uint64Value
    }
    func prepareInterruptedCommit(committed: Bool, placeholder: Bool = false) throws -> (Data, Data) {
        _ = try importer.importProfile(directory: "Profile 2", expectedBrowserVersion: "156.0.8078.80")
        let old = try Data(contentsOf: metadata)
        var next = try JSONSerialization.jsonObject(with: old) as! [String: Any]
        next["snapshotID"] = UUID().uuidString; next["profileName"] = "Next snapshot"
        let new = try JSONSerialization.data(withJSONObject: next, options: [.sortedKeys])
        let parent = destination.deletingLastPathComponent()
        let stage = parent.appendingPathComponent(".Profile.import-test")
        let displaced = parent.appendingPathComponent(".Profile.previous.discard-test")
        try fm.copyItem(at: destination, to: stage)
        try new.write(to: stage.appendingPathComponent(".dechrome-profile-import.json"), options: .atomic)
        let oldID = try inode(destination)
        try json(["stageName": stage.lastPathComponent, "displacedBackupName": displaced.lastPathComponent,
                  "hadDestination":true, "oldDestinationID": oldID,
                  "oldMetadata":old.base64EncodedString(), "newMetadata":new.base64EncodedString()],
                 destination.appendingPathExtension("import-journal.json"))
        try fm.moveItem(at: previous, to: displaced)
        try fm.moveItem(at: destination, to: previous)
        if committed { try fm.moveItem(at: stage, to: destination) }
        else if placeholder { try fm.createDirectory(at: destination, withIntermediateDirectories: false) }
        return (old, new)
    }
}

@main
private struct ProfileImportTests {
    static func main() throws {
        var passed = 0
        func test(_ name: String, _ block: () throws -> Void) throws {
            try block(); passed += 1; print("PASS \(name)")
        }
        try test("profile discovery uses safe source metadata") {
            let f = try ImportFixture()
            let link = f.source.appendingPathComponent("Profile 3")
            try f.fm.createSymbolicLink(at: link, withDestinationURL: f.selected)
            var state = try JSONSerialization.jsonObject(with: Data(contentsOf: f.source.appendingPathComponent("Local State"))) as! [String: Any]
            var profile = state["profile"] as! [String: Any]; var cache = profile["info_cache"] as! [String: Any]
            cache["Profile 3"] = ["name":"Symlink"]; profile["info_cache"] = cache; state["profile"] = profile
            try f.json(state, f.source.appendingPathComponent("Local State"))
            let profiles = try f.importer.listProfiles()
            try expect(Set(profiles.map(\.directory)) == ["Default", "Profile 2"], "unsafe or missing source profile was listed")
            try expect(profiles.first { $0.directory == "Profile 2" }?.userName == "work@example.invalid", "profile name/account missing")
        }
        try test("selected profile snapshot and filtered native hosts") {
            let f = try ImportFixture(); let sourceBefore = try f.text(f.selected.appendingPathComponent("Preferences"))
            let state = try f.importer.importProfile(directory: "Profile 2", expectedBrowserVersion: "156.0.8078.80")
            try expect(state.sourceDirectory == "Profile 2", "selected directory changed")
            try expect(try f.text(f.destination.appendingPathComponent("Profile 2/History-wal")) == "committed-wal", "SQLite WAL not copied")
            try expect(try f.text(f.destination.appendingPathComponent("Profile 2/Sessions/Session_1")) == "saved-session", "session not copied")
            try expect(!f.fm.fileExists(atPath: f.destination.appendingPathComponent("Default").path), "unselected profile copied")
            try expect(!f.fm.fileExists(atPath: f.destination.appendingPathComponent("Profile 2/Cache").path), "cache copied")
            try expect(!f.fm.fileExists(atPath: f.destination.appendingPathComponent("Profile 2/Code Cache").path), "code cache copied")
            try expect(try f.text(f.destination.appendingPathComponent("Profile 2/Extensions/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/1.0/Cache/script.js")) == "real-extension-asset", "extension asset directory was mistaken for browser cache")
            try expect(try f.text(f.destination.appendingPathComponent("Profile 2/Extensions/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/1.0/Singleton.js")) == "real-singleton-asset", "extension asset was mistaken for browser lock")
            try expect((try? f.fm.destinationOfSymbolicLink(atPath: f.destination.appendingPathComponent("Profile 2/SingletonLock").path)) == nil, "lock copied")
            try expect(!f.fm.fileExists(atPath: f.destination.appendingPathComponent("DevToolsActivePort").path), "debugger record copied")
            let local = try JSONSerialization.jsonObject(with: Data(contentsOf: f.destination.appendingPathComponent("Local State"))) as! [String: Any]
            let cache = (local["profile"] as! [String: Any])["info_cache"] as! [String: Any]
            try expect(Set(cache.keys) == ["Profile 2"] && local["unrelated_account_cache"] == nil, "unselected account metadata copied")
            try expect(local["os_crypt"] != nil, "shared crypto configuration lost")
            try expect(f.fm.fileExists(atPath: f.destination.appendingPathComponent("NativeMessagingHosts/native.work.json").path), "work native host missing")
            try expect(f.fm.fileExists(atPath: f.destination.appendingPathComponent("NativeMessagingHosts/native.external.json").path), "selected external extension's native host missing")
            try expect(!f.fm.fileExists(atPath: f.destination.appendingPathComponent("NativeMessagingHosts/native.other.json").path), "unrelated native host copied")
            try expect(try f.text(f.selected.appendingPathComponent("Preferences")) == sourceBefore, "source changed")
            try expect(try f.text(f.previous.appendingPathComponent("Existing")) == "old-destination", "previous destination missing")
            try expect(f.importer.currentImport()?.snapshotID == state.snapshotID, "import state not persisted")
        }
        try test("one-way refresh preserves previous destination in backup") {
            let f = try ImportFixture(); let before = try f.importer.importProfile(directory: "Profile 2", expectedBrowserVersion: "156.0.8078.80")
            try f.write("dechrome-only", f.destination.appendingPathComponent("Profile 2/Preferences"))
            try f.write("source-updated", f.selected.appendingPathComponent("Preferences"))
            let after = try f.importer.refresh(expectedBrowserVersion: "156.0.8078.80")
            try expect(before.snapshotID != after.snapshotID, "refresh reused snapshot ID")
            try expect(try f.text(f.destination.appendingPathComponent("Profile 2/Preferences")) == "source-updated", "source not refreshed")
            try expect(try f.text(f.previous.appendingPathComponent("Profile 2/Preferences")) == "dechrome-only", "DeChrome edits not backed up")
            try expect(try f.text(f.selected.appendingPathComponent("Preferences")) == "source-updated", "refresh wrote back to source")
        }
        try test("copy failure preserves profile and metadata") {
            let f = try ImportFixture(); let old = try f.importer.importProfile(directory: "Profile 2", expectedBrowserVersion: "156.0.8078.80")
            let importer = f.make(copier: { _, _ in throw NSError(domain: "synthetic-copy-failure", code: 1) })
            try fails("copy failure") { _ = try importer.refresh(expectedBrowserVersion: "156.0.8078.80") }
            try expect(importer.currentImport()?.snapshotID == old.snapshotID, "metadata changed on failed copy")
            try expect(try f.text(f.destination.appendingPathComponent("Profile 2/Preferences")) == "work-preferences", "destination changed on failed copy")
        }
        try test("running source or destination refuses import") {
            for blockSource in [true, false] {
                let f = try ImportFixture()
                let importer = f.make(guardCheck: { url in
                    if url == (blockSource ? f.source : f.destination) { throw NSError(domain:"synthetic-running",code:1) }
                })
                try fails("running browser") { _ = try importer.importProfile(directory: "Profile 2", expectedBrowserVersion: "156.0.8078.80") }
                try expect(try f.text(f.destination.appendingPathComponent("Existing")) == "old-destination", "live refusal changed destination")
            }
        }
        try test("default guard refuses an active profile lock") {
            let f = try ImportFixture()
            try f.fm.createSymbolicLink(atPath: f.source.appendingPathComponent("SingletonLock").path,
                                        withDestinationPath: "test-host-\(getpid())")
            let importer = DCProfileImporter(destinationRoot:f.destination, metadataURL:f.metadata, sourceRoot:f.source)
            try fails("live lock") { _ = try importer.importProfile(directory:"Profile 2",expectedBrowserVersion:"156.0.8078.80") }
            try expect((try? f.fm.destinationOfSymbolicLink(atPath:f.source.appendingPathComponent("SingletonLock").path)) != nil, "source lock removed")
        }
        try test("source version guard rejects newer missing and corrupt records") {
            for version in ["157.0.0.0", "not-a-version", ""] {
                let f = try ImportFixture()
                if version.isEmpty { try f.fm.removeItem(at:f.source.appendingPathComponent("Last Version")) }
                else { try f.write(version, f.source.appendingPathComponent("Last Version")) }
                try fails("version guard") { _ = try f.importer.importProfile(directory:"Profile 2",expectedBrowserVersion:"156.0.8078.80") }
                try expect(try f.text(f.destination.appendingPathComponent("Existing")) == "old-destination", "version failure changed data")
            }
        }
        try test("unexpected profile symlink is rejected") {
            let f = try ImportFixture()
            try f.fm.createSymbolicLink(atPath:f.selected.appendingPathComponent("outside-link").path, withDestinationPath:"/private/tmp")
            try fails("profile symlink") { _ = try f.importer.importProfile(directory:"Profile 2",expectedBrowserVersion:"156.0.8078.80") }
            try expect(try f.text(f.destination.appendingPathComponent("Existing")) == "old-destination", "symlink rejection changed data")
        }
        try test("source mutations during copy abort transaction") {
            let f = try ImportFixture(); var changed = false
            let importer = f.make(copier: { source, destination in
                try f.fm.copyItem(at:source,to:destination)
                if !changed { changed=true; try f.write("changed-during-copy",f.selected.appendingPathComponent("Preferences")) }
            })
            try fails("source mutated") { _ = try importer.importProfile(directory:"Profile 2",expectedBrowserVersion:"156.0.8078.80") }
            try expect(try f.text(f.destination.appendingPathComponent("Existing")) == "old-destination", "mutation failure replaced destination")
        }
        try test("overlapping roots rejected without writing source") {
            let f = try ImportFixture(); let destination=f.source.appendingPathComponent("Bad/Profile")
            let importer=DCProfileImporter(destinationRoot:destination,metadataURL:f.source.appendingPathComponent("Bad/import.json"),sourceRoot:f.source,quiescenceCheck:{_ in})
            try fails("nested destination") { _ = try importer.importProfile(directory:"Profile 2",expectedBrowserVersion:"156.0.8078.80") }
            try expect(!f.fm.fileExists(atPath:f.source.appendingPathComponent("Bad").path),"overlap check wrote into source")
        }
        try test("source cannot alias backup or mutable metadata locations") {
            for path in ["Profile.previous", "Profile.import-journal.json", "Profile.import.lock", "imported-profile.json"] {
                let f = try ImportFixture(); let source=f.destination.deletingLastPathComponent().appendingPathComponent(path)
                try f.fm.copyItem(at:f.source,to:source)
                let importer=DCProfileImporter(destinationRoot:f.destination,metadataURL:f.metadata,sourceRoot:source,quiescenceCheck:{_ in})
                try fails("source aliases managed destination") { _ = try importer.importProfile(directory:"Profile 2",expectedBrowserVersion:"156.0.8078.80") }
                try expect(try f.text(source.appendingPathComponent("Profile 2/Preferences"))=="work-preferences","source backup/sidecar was modified")
                try expect(f.fm.fileExists(atPath:source.appendingPathComponent("Default/Bookmarks").path),"unselected source profile was lost")
            }
        }
        try test("absolute extension paths back into source are rejected without rewriting preferences") {
            let f = try ImportFixture()
            let preferences=f.selected.appendingPathComponent("Preferences")
            try f.json(["extensions":["settings":["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa":["path":f.selected.appendingPathComponent("Extensions/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/1.0").path]]]],preferences)
            let original=try Data(contentsOf:preferences)
            try fails("source-referencing extension") { _ = try f.importer.importProfile(directory:"Profile 2",expectedBrowserVersion:"156.0.8078.80") }
            try expect(try Data(contentsOf:preferences)==original,"protected source preferences were rewritten")
            try expect(try f.text(f.destination.appendingPathComponent("Existing"))=="old-destination","absolute-path refusal modified destination")
        }
        try test("saved metadata with missing selected directory fails closed") {
            let f = try ImportFixture(); _ = try f.importer.importProfile(directory:"Profile 2",expectedBrowserVersion:"156.0.8078.80")
            try f.fm.removeItem(at:f.destination.appendingPathComponent("Profile 2"))
            try fails("missing imported profile") { _ = try f.importer.validatedCurrentImport() }
        }
        try test("corrupt import metadata fails closed") {
            let f = try ImportFixture(); _ = try f.importer.importProfile(directory:"Profile 2",expectedBrowserVersion:"156.0.8078.80")
            try f.write("corrupt",f.destination.appendingPathComponent(".dechrome-profile-import.json"))
            try fails("corrupt metadata") { _ = try f.importer.validatedCurrentImport() }
            try fails("refresh corrupt metadata") { _ = try f.importer.refresh(expectedBrowserVersion:"156.0.8078.80") }
        }
        try test("interrupted swap restores old profile through runtime placeholder") {
            let f = try ImportFixture(); let (old,_) = try f.prepareInterruptedCommit(committed:false,placeholder:true)
            try f.importer.recoverIfNeeded()
            try expect(try Data(contentsOf:f.metadata)==old,"old metadata not restored")
            try expect(try f.text(f.destination.appendingPathComponent("Profile 2/Preferences"))=="work-preferences","old profile not restored")
            try expect(try f.text(f.previous.appendingPathComponent("Existing"))=="old-destination","older backup not restored")
        }
        try test("committed swap repairs metadata without consulting unavailable source") {
            let f = try ImportFixture(); let (_,new) = try f.prepareInterruptedCommit(committed:true)
            try f.fm.removeItem(at:f.source)
            var consultedSource=false
            let importer=f.make(guardCheck:{url in if url==f.source {consultedSource=true;throw NSError(domain:"source-offline",code:1)}})
            try importer.recoverIfNeeded()
            try expect(!consultedSource,"recovery consulted source")
            try expect(try Data(contentsOf:f.metadata)==new,"committed metadata not repaired")
            try expect(importer.currentImport()?.profileName=="Next snapshot","committed profile not selected")
        }
        try test("no recovery journal requires no source access") {
            let f = try ImportFixture(); try f.fm.removeItem(at:f.source)
            let importer=f.make(guardCheck:{_ in throw NSError(domain:"must-not-inspect",code:1)})
            try importer.recoverIfNeeded()
        }
        print("Profile import: \(passed) tests passed.")
    }
}
