import Foundation
import CoreFoundation
import Darwin

@_silgen_name("proc_pidpath")
private func dc_profile_proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> Int32
@_silgen_name("sysctl")
private func dc_profile_sysctl(_ name: UnsafeMutablePointer<Int32>, _ nameLength: UInt32,
                              _ oldValue: UnsafeMutableRawPointer?, _ oldLength: UnsafeMutablePointer<Int>,
                              _ newValue: UnsafeMutableRawPointer?, _ newLength: Int) -> Int32

struct DCChromeProfile: Codable {
    let directory: String
    let name: String
    let userName: String?
}

struct DCProfileImportState: Codable {
    let sourceRoot: String
    let sourceDirectory: String
    let profileName: String
    let importedAt: Date
    let sourceVersion: String?
    let snapshotID: String
}

private struct DCProfileImportFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// A stopped-browser, one-way snapshot. Never changes the source Chrome data.
final class DCProfileImporter {
    let destinationRoot: URL
    let metadataURL: URL
    let sourceRoot: URL
    var previousRoot: URL { destinationRoot.appendingPathExtension("previous") }
    private let fm = FileManager.default
    private let quiescenceCheck: ((URL) throws -> Void)?
    private let copyFile: (URL, URL) throws -> Void
    private let embeddedName = ".dechrome-profile-import.json"
    private var journalURL: URL { destinationRoot.appendingPathExtension("import-journal.json") }
    private var lockURL: URL { destinationRoot.appendingPathExtension("import.lock") }

    private struct Journal: Codable {
        let stageName: String
        let displacedBackupName: String
        let hadDestination: Bool
        let oldDestinationID: UInt64?
        let oldMetadata: Data?
        let newMetadata: Data
    }

    private struct Fingerprint: Equatable {
        let type: String
        let size: UInt64
        let modified: TimeInterval
        let inode: UInt64
    }

    static func defaultSourceRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let value = environment["DECHROME_PROFILE_SOURCE_DIR"], !value.isEmpty {
            return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
    }

    init(destinationRoot: URL, metadataURL: URL, sourceRoot: URL? = nil,
         quiescenceCheck: ((URL) throws -> Void)? = nil,
         copyFile: ((URL, URL) throws -> Void)? = nil) {
        self.destinationRoot = destinationRoot.standardizedFileURL
        self.metadataURL = metadataURL.standardizedFileURL
        self.sourceRoot = (sourceRoot ?? Self.defaultSourceRoot()).standardizedFileURL
        self.quiescenceCheck = quiescenceCheck
        self.copyFile = copyFile ?? { try FileManager.default.copyItem(at: $0, to: $1) }
    }

    func listProfiles() throws -> [DCChromeProfile] {
        try validateSourceRoot()
        let state = try localState()
        let profile = state["profile"] as? [String: Any]
        let cache = profile?["info_cache"] as? [String: Any] ?? [:]
        var result: [DCChromeProfile] = []
        for (directory, raw) in cache {
            guard validComponent(directory), let info = raw as? [String: Any] else { continue }
            let url = sourceRoot.appendingPathComponent(directory, isDirectory: true)
            do { try requireOwnedDirectory(url) } catch { continue }
            let name = (info["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? directory
            result.append(DCChromeProfile(directory: directory, name: name,
                                          userName: info["user_name"] as? String))
        }
        return result.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedSame ?
                $0.directory < $1.directory : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Embedded state moves atomically with the profile. External metadata is a
    /// convenience copy, repaired by recovery if a crash occurred after swap.
    func currentImport() -> DCProfileImportState? {
        if let state = try? decodeState(destinationRoot.appendingPathComponent(embeddedName)) { return state }
        return try? decodeState(metadataURL)
    }

    /// Validate metadata before a launcher chooses its imported profile folder.
    func validatedCurrentImport() throws -> DCProfileImportState? {
        let embedded = destinationRoot.appendingPathComponent(embeddedName)
        let state: DCProfileImportState
        if exists(embedded) { state = try decodeState(embedded) }
        else if exists(metadataURL) { state = try decodeState(metadataURL) }
        else { return nil }
        try requireOwnedDirectory(destinationRoot)
        try requireOwnedDirectory(destinationRoot.appendingPathComponent(state.sourceDirectory, isDirectory: true))
        return state
    }

    @discardableResult
    func importProfile(directory: String, expectedBrowserVersion: String) throws -> DCProfileImportState {
        try validateIndependentPaths()
        return try withLock { try importUnlocked(directory: directory, expectedBrowserVersion: expectedBrowserVersion) }
    }

    private func importUnlocked(directory: String, expectedBrowserVersion: String) throws -> DCProfileImportState {
            try recoverUnlocked()
            try validateSourceRoot()
            try validateIndependentPaths()
            try ensureQuiescent(sourceRoot, source: true)
            try ensureQuiescent(destinationRoot, source: false)
            guard let selected = try listProfiles().first(where: { $0.directory == directory }) else {
                throw DCProfileImportFailure("Choose an available Chrome profile before importing.")
            }
            guard validVersion(expectedBrowserVersion) else {
                throw DCProfileImportFailure("The installed Chrome version could not be verified.")
            }
            let sourceVersion = try readSourceVersion()
            if let sourceVersion, compareVersions(sourceVersion, expectedBrowserVersion) == .orderedDescending {
                throw DCProfileImportFailure("This Chrome profile was used by version \(sourceVersion), newer than installed Chrome \(expectedBrowserVersion). Update Chrome before importing.")
            }
            let state = DCProfileImportState(sourceRoot: sourceRoot.path, sourceDirectory: directory,
                profileName: selected.name, importedAt: Date(), sourceVersion: sourceVersion,
                snapshotID: UUID().uuidString)
            let bytes = try encoder().encode(state)
            let parent = destinationRoot.deletingLastPathComponent()
            let stage = parent.appendingPathComponent(".\(destinationRoot.lastPathComponent).import-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            var journalWritten = false
            defer { if !journalWritten { try? fm.removeItem(at: stage) } }
            let profile = sourceRoot.appendingPathComponent(directory, isDirectory: true)
            let before = try fingerprint(profile)
            try validateExtensionPaths(profile: profile)
            let originalLocalState = try localStateBytes()
            let nativeHosts = try selectedNativeHosts(profile: profile)
            try copyTree(profile, to: stage.appendingPathComponent(directory, isDirectory: true))
            let stateObject = try localStateObject(originalLocalState)
            try writeSelectedLocalState(stateObject, directory: directory, to: stage.appendingPathComponent("Local State"))
            if let sourceVersion { try secureWrite(Data((sourceVersion + "\n").utf8), stage.appendingPathComponent("Last Version")) }
            try copyNativeHosts(nativeHosts, to: stage)
            try secureWrite(bytes, stage.appendingPathComponent(embeddedName))
            try ensureQuiescent(sourceRoot, source: true)
            try ensureQuiescent(destinationRoot, source: false)
            guard try fingerprint(profile) == before, try localStateBytes() == originalLocalState,
                  try readSourceVersion() == sourceVersion,
                  try selectedNativeHosts(profile: profile) == nativeHosts else {
                throw DCProfileImportFailure("The source Chrome profile changed during import. Quit Chrome and retry; the current DeChrome profile was preserved.")
            }
            let displaced = parent.appendingPathComponent(".\(previousRoot.lastPathComponent).discard-\(UUID().uuidString)")
            let journal = Journal(stageName: stage.lastPathComponent,
                                  displacedBackupName: displaced.lastPathComponent,
                                  hadDestination: exists(destinationRoot),
                                  oldDestinationID: exists(destinationRoot) ? (try ownedAttributes(destinationRoot)[.systemFileNumber] as? NSNumber)?.uint64Value : nil,
                                  oldMetadata: try readOptionalData(metadataURL), newMetadata: bytes)
            try secureWrite(try encoder().encode(journal), journalURL)
            journalWritten = true
            do {
                if exists(previousRoot) { try requireOwnedDirectory(previousRoot); try fm.moveItem(at: previousRoot, to: displaced) }
                if exists(destinationRoot) { try requireOwnedDirectory(destinationRoot); try fm.moveItem(at: destinationRoot, to: previousRoot) }
                try fm.moveItem(at: stage, to: destinationRoot)
                try secureWrite(bytes, metadataURL)
                if exists(displaced) { try fm.removeItem(at: displaced) }
                try fm.removeItem(at: journalURL)
            } catch {
                // Filesystem state and the embedded transaction ID decide
                // whether the swap committed; never guess from a stale phase.
                try recoverUnlocked()
                if currentImport()?.snapshotID == state.snapshotID { return state }
                throw error
            }
            return state
    }

    @discardableResult
    func refresh(expectedBrowserVersion: String) throws -> DCProfileImportState {
        try validateIndependentPaths()
        return try withLock {
            try recoverUnlocked()
            guard let state = try validatedCurrentImport() else {
                throw DCProfileImportFailure("Import a Chrome profile before using Update from Chrome.")
            }
            guard canonical(URL(fileURLWithPath: state.sourceRoot)) == canonical(sourceRoot) else {
                throw DCProfileImportFailure("The saved source profile location changed. Select its original Chrome folder before updating.")
            }
            return try importUnlocked(directory: state.sourceDirectory, expectedBrowserVersion: expectedBrowserVersion)
        }
    }

    func recoverIfNeeded() throws {
        guard exists(journalURL) else { return }
        try validateIndependentPaths()
        try withLock { try recoverUnlocked() }
    }

    private func recoverUnlocked() throws {
        guard exists(journalURL) else { return }
        try ensureQuiescent(destinationRoot, source: false)
        try requireOwnedRegularFile(journalURL)
        let journal: Journal
        do { journal = try decoder().decode(Journal.self, from: Data(contentsOf: journalURL)) }
        catch { throw DCProfileImportFailure("The profile import recovery record is unreadable. Profile files were preserved for recovery.") }
        guard validComponent(journal.stageName), journal.stageName.hasPrefix(".\(destinationRoot.lastPathComponent).import-"),
              validComponent(journal.displacedBackupName), journal.displacedBackupName.hasPrefix(".\(previousRoot.lastPathComponent).discard-") else {
            throw DCProfileImportFailure("The profile import recovery record contains an unsafe path. Profile files were preserved.")
        }
        let parent = destinationRoot.deletingLastPathComponent()
        let stage = parent.appendingPathComponent(journal.stageName)
        let displaced = parent.appendingPathComponent(journal.displacedBackupName)
        if exists(destinationRoot), !exists(stage),
           try readOptionalData(destinationRoot.appendingPathComponent(embeddedName)) == journal.newMetadata {
            try requireOwnedDirectory(destinationRoot)
            try secureWrite(journal.newMetadata, metadataURL)
            if exists(displaced) { try requireOwnedDirectory(displaced); try fm.removeItem(at: displaced) }
            try fm.removeItem(at: journalURL)
            return
        }
        guard exists(stage) else {
            throw DCProfileImportFailure("The interrupted profile import could not be safely classified. Profile files were preserved.")
        }
        try requireOwnedDirectory(stage)
        if journal.hadDestination, exists(destinationRoot), exists(previousRoot),
           let oldID = journal.oldDestinationID,
           (try ownedAttributes(destinationRoot)[.systemFileNumber] as? NSNumber)?.uint64Value != oldID {
            guard try fm.contentsOfDirectory(atPath: destinationRoot.path).isEmpty else {
                throw DCProfileImportFailure("An unexpected profile folder appeared during import recovery. All profile copies were preserved.")
            }
            // Runtime directory setup may recreate an empty placeholder after
            // the previous destination was moved aside during an interrupted swap.
            try fm.removeItem(at: destinationRoot)
        }
        if journal.hadDestination && !exists(destinationRoot) {
            guard exists(previousRoot) else {
                throw DCProfileImportFailure("The previous profile is missing during recovery. Remaining profile files were preserved.")
            }
            try requireOwnedDirectory(previousRoot)
            try fm.moveItem(at: previousRoot, to: destinationRoot)
        }
        if exists(displaced) {
            guard !exists(previousRoot) else {
                throw DCProfileImportFailure("Both previous-profile locations exist during recovery. Files were preserved instead of overwriting a backup.")
            }
            try requireOwnedDirectory(displaced)
            try fm.moveItem(at: displaced, to: previousRoot)
        }
        if let old = journal.oldMetadata { try secureWrite(old, metadataURL) }
        else if exists(metadataURL) { try requireOwnedRegularFile(metadataURL); try fm.removeItem(at: metadataURL) }
        try fm.removeItem(at: stage)
        try fm.removeItem(at: journalURL)
    }

    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        let parent = destinationRoot.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try requireOwnedDirectory(parent)
        guard metadataURL.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL,
              ![destinationRoot, previousRoot, journalURL, lockURL].contains(metadataURL) else {
            throw DCProfileImportFailure("Import metadata must be stored next to the independent DeChrome profile.")
        }
        if exists(lockURL) { try requireOwnedRegularFile(lockURL) }
        let descriptor = Darwin.open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw DCProfileImportFailure("Could not open the profile import lock.") }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw DCProfileImportFailure("Another profile import or refresh is already running.")
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func validateSourceRoot() throws { try requireOwnedDirectory(sourceRoot); _ = try localStateBytes() }
    private func validateIndependentPaths() throws {
        let source = canonical(sourceRoot), destination = canonical(destinationRoot)
        let managed = [destinationRoot, previousRoot, metadataURL, journalURL, lockURL].map(canonical)
        let parent = canonical(destinationRoot.deletingLastPathComponent())
        let reservedStage = parent + "/.\(destinationRoot.lastPathComponent).import-"
        let reservedBackup = parent + "/.\(previousRoot.lastPathComponent).discard-"
        guard !managed.contains(where: { source == $0 || source.hasPrefix($0 + "/") || $0.hasPrefix(source + "/") }),
              !source.hasPrefix(reservedStage), !source.hasPrefix(reservedBackup),
              destination != canonical(Self.defaultSourceRoot(environment: [:])) else {
            throw DCProfileImportFailure("Chrome and DeChrome must use independent profile folders. The source Chrome profile was not changed.")
        }
        if exists(destinationRoot) { try requireOwnedDirectory(destinationRoot) }
        if exists(previousRoot) { try requireOwnedDirectory(previousRoot) }
        if exists(metadataURL) { try requireOwnedRegularFile(metadataURL) }
    }

    private func localStateBytes() throws -> Data {
        let file = sourceRoot.appendingPathComponent("Local State")
        try requireOwnedRegularFile(file)
        return try Data(contentsOf: file)
    }
    private func localState() throws -> [String: Any] { try localStateObject(localStateBytes()) }
    private func localStateObject(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DCProfileImportFailure("Chrome's Local State file is unreadable. The source profile was not changed.")
        }
        return value
    }
    private func writeSelectedLocalState(_ state: [String: Any], directory: String, to destination: URL) throws {
        let profile = state["profile"] as? [String: Any] ?? [:]
        let info = (profile["info_cache"] as? [String: Any])?[directory] ?? [:]
        var selected: [String: Any] = ["profile": ["info_cache": [directory: info], "last_used": directory,
                                                    "last_active_profiles": [directory]]]
        // The OS crypto configuration is shared by profiles; unrelated account
        // caches, telemetry IDs and other profile metadata are not imported.
        if let crypto = state["os_crypt"] as? [String: Any] { selected["os_crypt"] = crypto }
        try secureWrite(try JSONSerialization.data(withJSONObject: selected, options: [.prettyPrinted, .sortedKeys]), destination)
    }
    private func readSourceVersion() throws -> String? {
        let file = sourceRoot.appendingPathComponent("Last Version")
        guard exists(file) else {
            throw DCProfileImportFailure("Chrome's profile-version record is missing. Open and quit regular Chrome once, then retry the import.")
        }
        try requireOwnedRegularFile(file)
        let version = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard validVersion(version) else { throw DCProfileImportFailure("Chrome's profile-version record is unreadable. Import was stopped to avoid a browser downgrade.") }
        return version
    }
    private func validVersion(_ version: String) -> Bool {
        version.range(of: "^[0-9]+(?:\\.[0-9]+)*$", options: .regularExpression) != nil
    }
    private func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = lhs.split(separator: ".").map { UInt64($0) ?? UInt64.max }
        let b = rhs.split(separator: ".").map { UInt64($0) ?? UInt64.max }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private func shouldSkip(_ relative: String) -> Bool {
        let parts = relative.split(separator: "/").map(String.init)
        let transient: Set<String> = ["Cache", "Code Cache", "GPUCache", "DawnCache", "GrShaderCache", "ShaderCache", "Media Cache", "Crashpad", "BrowserMetrics", "BrowserMetrics-spare.pma"]
        let locks: Set<String> = ["SingletonLock", "SingletonCookie", "SingletonSocket", "SingletonToken", "DevToolsActivePort"]
        return parts.first.map { transient.contains($0) || locks.contains($0) } ?? false
    }
    private func relativePath(_ item: URL, in root: URL) throws -> String {
        let base = canonical(root), parent = canonical(item.deletingLastPathComponent())
        guard parent == base || parent.hasPrefix(base + "/") else {
            throw DCProfileImportFailure("A profile entry escaped its source folder. Import was stopped.")
        }
        let relativeParent = parent == base ? "" : String(parent.dropFirst(base.count + 1)) + "/"
        return relativeParent + item.lastPathComponent
    }
    private func entries(_ root: URL) throws -> [URL] {
        var enumerationError: Error?
        guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [], errorHandler: { _, error in enumerationError = error; return false }) else {
            throw DCProfileImportFailure("The selected Chrome profile could not be enumerated.")
        }
        var result: [URL] = []
        while let item = iterator.nextObject() as? URL {
            let relative = try relativePath(item, in: root)
            if shouldSkip(relative) { iterator.skipDescendants(); continue }
            result.append(item)
        }
        if let enumerationError { throw enumerationError }
        return result.sorted { $0.path < $1.path }
    }
    private func fingerprint(_ root: URL) throws -> [String: Fingerprint] {
        try requireOwnedDirectory(root)
        var result: [String: Fingerprint] = [:]
        for item in try entries(root) {
            let attributes = try ownedAttributes(item)
            let type = attributes[.type] as? FileAttributeType
            guard type == .typeDirectory || type == .typeRegular else {
                throw DCProfileImportFailure("The selected profile contains a symbolic link or special file. Import stopped without changing either profile.")
            }
            result[try relativePath(item, in: root)] = Fingerprint(type: type!.rawValue,
                size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                modified: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
        }
        return result
    }
    private func copyTree(_ source: URL, to destination: URL) throws {
        try requireOwnedDirectory(source)
        try fm.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var lastCheck = Date.distantPast
        for item in try entries(source) {
            if Date().timeIntervalSince(lastCheck) > 0.2 {
                try ensureQuiescent(sourceRoot, source: true)
                try ensureQuiescent(destinationRoot, source: false)
                lastCheck = Date()
            }
            let attrs = try ownedAttributes(item)
            let relative = try relativePath(item, in: source)
            let target = destination.appendingPathComponent(relative)
            if attrs[.type] as? FileAttributeType == .typeDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            } else if attrs[.type] as? FileAttributeType == .typeRegular {
                try copyFile(item, target)
                let ownerExecutable = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
                try fm.setAttributes([.posixPermissions: 0o600 | (ownerExecutable & 0o100)], ofItemAtPath: target.path)
            } else { throw DCProfileImportFailure("A profile file changed to a symbolic link or special file during import. Retry with Chrome closed.") }
        }
    }
    private func extensionSettings(profile: URL) throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        for name in ["Preferences", "Secure Preferences"] {
            let file = profile.appendingPathComponent(name)
            guard exists(file) else { continue }
            try requireOwnedRegularFile(file)
            guard let preferences = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any] else {
                throw DCProfileImportFailure("Chrome's \(name) file is unreadable. Open and quit regular Chrome, then retry.")
            }
            let settings = (preferences["extensions"] as? [String: Any])?["settings"] as? [String: Any] ?? [:]
            result.append(settings)
        }
        return result
    }
    private func validateExtensionPaths(profile: URL) throws {
        let source = canonical(sourceRoot)
        for settings in try extensionSettings(profile: profile) {
            for entry in settings.values {
                guard let info = entry as? [String: Any], let path = info["path"] as? String, path.hasPrefix("/") else { continue }
                let absolute = canonical(URL(fileURLWithPath: path))
                if absolute == source || absolute.hasPrefix(source + "/") || source.hasPrefix(absolute + "/") {
                    throw DCProfileImportFailure("An extension refers directly to files in the original Chrome profile. Import cannot safely isolate that extension; its protected preferences were not rewritten. Use a fresh DeChrome profile for that extension.")
                }
            }
        }
    }
    private func selectedNativeHosts(profile: URL) throws -> [String: Data] {
        let extensions = profile.appendingPathComponent("Extensions", isDirectory: true)
        var ids = Set(((try? fm.contentsOfDirectory(atPath: extensions.path)) ?? [])
            .filter { $0.range(of: "^[a-p]{32}$", options: .regularExpression) != nil })
        for settings in try extensionSettings(profile: profile) {
            ids.formUnion(settings.keys.filter { $0.range(of: "^[a-p]{32}$", options: .regularExpression) != nil })
        }
        guard !ids.isEmpty else { return [:] }
        let hosts = sourceRoot.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
        guard exists(hosts) else { return [:] }
        try requireOwnedDirectory(hosts)
        var result: [String: Data] = [:]
        for file in try fm.contentsOfDirectory(at: hosts, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) where file.pathExtension == "json" {
            try requireOwnedRegularFile(file)
            let bytes = try Data(contentsOf: file)
            guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let origins = object["allowed_origins"] as? [String],
                  origins.contains(where: { origin in ids.contains { origin == "chrome-extension://\($0)/" } }) else { continue }
            result[file.lastPathComponent] = bytes
        }
        return result
    }
    private func copyNativeHosts(_ hosts: [String: Data], to stage: URL) throws {
        guard !hosts.isEmpty else { return }
        let destination = stage.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for (name, bytes) in hosts { try secureWrite(bytes, destination.appendingPathComponent(name)) }
    }

    private func ensureQuiescent(_ root: URL, source: Bool) throws {
        if let quiescenceCheck { try quiescenceCheck(root); return }
        let lock = root.appendingPathComponent("SingletonLock")
        if let link = try? fm.destinationOfSymbolicLink(atPath: lock.path) {
            guard let tail = link.split(separator: "-").last, let pid = Int32(tail), pid > 0 else {
                throw DCProfileImportFailure("Chrome's profile lock could not be verified. Quit Chrome normally and retry; its lock was not removed.")
            }
            if Darwin.kill(pid, 0) == 0 || errno == EPERM {
                throw DCProfileImportFailure("Quit regular Chrome and DeChrome before importing or updating a profile. Chrome process \(pid) still owns a profile lock.")
            }
        } else if exists(lock) {
            try requireOwnedRegularFile(lock)
            let descriptor = Darwin.open(lock.path, O_RDONLY | O_NOFOLLOW)
            guard descriptor >= 0 else { throw DCProfileImportFailure("Chrome's profile lock could not be inspected.") }
            defer { Darwin.close(descriptor) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw DCProfileImportFailure("Quit regular Chrome and DeChrome before importing or updating a profile.")
            }
            flock(descriptor, LOCK_UN)
        }
        let listing = try run("/bin/ps", ["-ww", "-axo", "pid=,stat=,command="])
        for line in listing.split(whereSeparator: \.isNewline) where line.contains("Google Chrome") {
            let columns = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard columns.count == 3, let pid = Int32(columns[0]), pid > 1,
                  !columns[1].hasPrefix("Z") else { continue }
            guard let executable = processExecutable(pid) else {
                if Darwin.kill(pid, 0) == 0 || errno == EPERM { throw DCProfileImportFailure("macOS did not allow Chrome processes to be inspected. Profile import was stopped without changing data.") }
                continue
            }
            guard executable.hasSuffix("/Google Chrome.app/Contents/MacOS/Google Chrome") else { continue }
            guard let arguments = processArguments(pid) else {
                if Darwin.kill(pid, 0) == 0 || errno == EPERM { throw DCProfileImportFailure("macOS did not allow Chrome's profile arguments to be inspected. Quit Chrome and retry.") }
                continue
            }
            var explicitRoot: String?
            for (index, arg) in arguments.enumerated() {
                if arg.hasPrefix("--user-data-dir=") { explicitRoot = String(arg.dropFirst("--user-data-dir=".count)) }
                if arg == "--user-data-dir", index + 1 < arguments.count { explicitRoot = arguments[index + 1] }
            }
            if let explicitRoot {
                if canonical(URL(fileURLWithPath: explicitRoot)) != canonical(root) { continue }
            } else if !source && canonical(root) != canonical(Self.defaultSourceRoot(environment: [:])) { continue }
            throw DCProfileImportFailure("Quit regular Chrome and DeChrome before importing or updating a profile. Chrome process \(pid) is still running.")
        }
        let socket = root.appendingPathComponent("SingletonSocket")
        if fm.fileExists(atPath: socket.path), (try? fm.destinationOfSymbolicLink(atPath: lock.path)) == nil {
            throw DCProfileImportFailure("A Chrome profile socket still exists and could not be verified as inactive. Open and quit Chrome normally, then retry; no source lock was removed.")
        }
    }

    private func processExecutable(_ pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBytes { dc_profile_proc_pidpath(pid, $0.baseAddress!, UInt32($0.count)) }
        return count > 0 ? String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self) : nil
    }
    private func processArguments(_ pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard mib.withUnsafeMutableBufferPointer({ dc_profile_sysctl($0.baseAddress!, UInt32($0.count), nil, &size, nil, 0) }) == 0,
              size > MemoryLayout<Int32>.size, size <= 4 * 1024 * 1024 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard mib.withUnsafeMutableBufferPointer({ m in bytes.withUnsafeMutableBytes {
            dc_profile_sysctl(m.baseAddress!, UInt32(m.count), $0.baseAddress, &size, nil, 0)
        } }) == 0 else { return nil }
        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { $0.copyBytes(from: bytes.prefix(MemoryLayout<Int32>.size)) }
        guard argc > 0, argc < 131_072 else { return nil }
        var index = MemoryLayout<Int32>.size
        while index < size && bytes[index] != 0 { index += 1 }
        while index < size && bytes[index] == 0 { index += 1 }
        var result: [String] = []
        for _ in 0..<argc {
            let start = index
            while index < size && bytes[index] != 0 { index += 1 }
            guard index < size, let text = String(bytes: bytes[start..<index], encoding: .utf8) else { return nil }
            result.append(text); index += 1
        }
        return result
    }
    private func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DCProfileImportFailure("Chrome processes could not be inspected. Import was stopped without changing data.") }
        return String(decoding: data, as: UTF8.self)
    }

    private func canonical(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
    private func exists(_ url: URL) -> Bool { (try? fm.attributesOfItem(atPath: url.path)) != nil }
    private func validComponent(_ text: String) -> Bool {
        !text.isEmpty && text != "." && text != ".." && !text.contains("/") && !text.contains("\0")
    }
    private func ownedAttributes(_ url: URL) throws -> [FileAttributeKey: Any] {
        let attrs = try fm.attributesOfItem(atPath: url.path)
        guard (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == Darwin.getuid() else {
            throw DCProfileImportFailure("A profile file is not owned by the current user. Import was stopped without changing data.")
        }
        return attrs
    }
    private func requireOwnedDirectory(_ url: URL) throws {
        guard try ownedAttributes(url)[.type] as? FileAttributeType == .typeDirectory else {
            throw DCProfileImportFailure("A profile folder is missing, symbolic, or not a normal directory: \(url.lastPathComponent).")
        }
    }
    private func requireOwnedRegularFile(_ url: URL) throws {
        guard try ownedAttributes(url)[.type] as? FileAttributeType == .typeRegular else {
            throw DCProfileImportFailure("A profile file is symbolic or not a regular file: \(url.lastPathComponent).")
        }
    }
    private func secureWrite(_ data: Data, _ url: URL) throws {
        if exists(url) { try requireOwnedRegularFile(url) }
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func readOptionalData(_ url: URL) throws -> Data? {
        guard exists(url) else { return nil }; try requireOwnedRegularFile(url); return try Data(contentsOf: url)
    }
    private func decodeState(_ url: URL) throws -> DCProfileImportState {
        try requireOwnedRegularFile(url)
        do {
            let state = try decoder().decode(DCProfileImportState.self, from: Data(contentsOf: url))
            guard validComponent(state.sourceDirectory), state.sourceRoot.hasPrefix("/"), !state.snapshotID.isEmpty else { throw DCProfileImportFailure("Invalid profile metadata.") }
            return state
        } catch { throw DCProfileImportFailure("The imported-profile metadata is unreadable. Profile data was preserved; recover it before launching or refreshing.") }
    }
    private func encoder() -> JSONEncoder {
        let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601; value.outputFormatting = [.prettyPrinted, .sortedKeys]; return value
    }
    private func decoder() -> JSONDecoder { let value = JSONDecoder(); value.dateDecodingStrategy = .iso8601; return value }
}
