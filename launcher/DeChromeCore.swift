import Foundation
import CoreFoundation
import Darwin

@_silgen_name("proc_pidpath")
private func dc_proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> Int32

@_silgen_name("sysctl")
private func dc_sysctl(_ name: UnsafeMutablePointer<Int32>, _ nameLength: UInt32,
                       _ oldValue: UnsafeMutableRawPointer?, _ oldLength: UnsafeMutablePointer<Int>,
                       _ newValue: UnsafeMutableRawPointer?, _ newLength: Int) -> Int32

struct DCFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct DCPaths: Codable {
    let resourcesURL: URL
    let dataURL: URL
    let logsURL: URL
    let browserRoot: URL
    let browserApp: URL
    let previousRoot: URL
    let profileURL: URL
    let stateURL: URL
    let metadataURL: URL
    let lockURL: URL

    init(resourcesURL: URL, dataURL: URL, logsURL: URL) {
        self.resourcesURL = resourcesURL.standardizedFileURL
        self.dataURL = dataURL.standardizedFileURL
        self.logsURL = logsURL.standardizedFileURL
        browserRoot = self.dataURL.appendingPathComponent("Browser", isDirectory: true)
        browserApp = browserRoot.appendingPathComponent("Google Chrome.app", isDirectory: true)
        previousRoot = self.dataURL.appendingPathComponent("Browser.previous", isDirectory: true)
        profileURL = self.dataURL.appendingPathComponent("Profile", isDirectory: true)
        stateURL = self.dataURL.appendingPathComponent("process.json")
        metadataURL = browserRoot.appendingPathComponent("prepared.json")
        lockURL = self.dataURL.appendingPathComponent("operation.lock")
    }
}

struct DCPreparation: Codable {
    let changed: Bool
    let previousVersion: String?
    let version: String
    let browserPath: String
}

struct DCProcessState: Codable {
    let pid: Int32
    let url: String
    let executable: String
    let profile: String
    let startedAt: Date
    let processBirth: String
    let browserVersion: String
    let stock: Bool
}

struct DCDiagnostic: Codable {
    let level: String
    let name: String
    let detail: String
}

struct DCPrepared: Codable {
    let version: String
    let sourcePath: String
    let preparedAt: Date
}

struct DCProfileVersion: Codable { let version: String }

final class DeChromeRuntime {
    let paths: DCPaths
    let sourceChromeURL: URL
    private let fm = FileManager.default
    private let environment = ProcessInfo.processInfo.environment

    init(resourcesURL: URL, dataURL: URL? = nil, logsURL: URL? = nil,
         sourceChromeURL: URL? = nil) {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let data = dataURL ?? env["DECHROME_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent("Library/Application Support/DeChrome", isDirectory: true)
        let logs = logsURL ?? env["DECHROME_LOG_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent("Library/Logs/DeChrome", isDirectory: true)
        paths = DCPaths(resourcesURL: resourcesURL, dataURL: data, logsURL: logs)
        if let supplied = sourceChromeURL {
            self.sourceChromeURL = supplied.standardizedFileURL
        } else if let supplied = env["DECHROME_CHROME_PATH"], !supplied.isEmpty {
            self.sourceChromeURL = URL(fileURLWithPath: supplied, isDirectory: true).standardizedFileURL
        } else {
            let system = URL(fileURLWithPath: "/Applications/Google Chrome.app", isDirectory: true)
            let personal = home.appendingPathComponent("Applications/Google Chrome.app", isDirectory: true)
            self.sourceChromeURL = FileManager.default.fileExists(atPath: system.path) ? system : personal
        }
    }

    func prepare(force: Bool = false) throws -> DCPreparation {
        try withOperationLock {
            try refuseRunningBrowser()
            try profileImporter().recoverIfNeeded()
            return try prepareUnlocked(force: force)
        }
    }

    private func profileImporter(sourceRoot: URL? = nil) -> DCProfileImporter {
        let metadata = paths.dataURL.appendingPathComponent("imported-profile.json")
        let initial = DCProfileImporter(destinationRoot: paths.profileURL, metadataURL: metadata,
            sourceRoot: sourceRoot ?? DCProfileImporter.defaultSourceRoot(environment: environment))
        if sourceRoot == nil, let state = initial.currentImport() {
            return DCProfileImporter(destinationRoot: paths.profileURL, metadataURL: metadata,
                sourceRoot: URL(fileURLWithPath: state.sourceRoot, isDirectory: true))
        }
        return initial
    }

    func availableChromeProfiles(sourceRoot: URL? = nil) throws -> [DCChromeProfile] {
        try profileImporter(sourceRoot: sourceRoot).listProfiles()
    }

    func importedProfile() -> DCProfileImportState? { profileImporter().currentImport() }

    func importChromeProfile(directory: String, sourceRoot: URL? = nil) throws -> DCProfileImportState {
        try validateImportSourceLocation(profileImporter(sourceRoot: sourceRoot).sourceRoot)
        return try withOperationLock {
            try refuseRunningBrowser()
            let importer = profileImporter(sourceRoot: sourceRoot)
            try importer.recoverIfNeeded()
            return try importer.importProfile(directory: directory,
                expectedBrowserVersion: browserVersion(sourceChromeURL))
        }
    }

    func refreshChromeProfile(expectedSnapshotID: String? = nil) throws -> DCProfileImportState {
        try validateImportSourceLocation(profileImporter().sourceRoot)
        return try withOperationLock {
            try refuseRunningBrowser()
            let importer = profileImporter()
            try importer.recoverIfNeeded()
            if let expectedSnapshotID,
               try importer.validatedCurrentImport()?.snapshotID != expectedSnapshotID {
                throw DCFailure("The imported profile changed in another window. Refresh the profile list, then review Update from Chrome again.")
            }
            return try importer.refresh(expectedBrowserVersion: browserVersion(sourceChromeURL))
        }
    }

    func launch(url: String? = nil, diagnose: Bool = false, stock: Bool = false, tabs: Bool = false) throws -> DCProcessState {
        try withOperationLock {
            if let running = try status() {
                throw DCFailure("DeChrome is already running (PID \(running.pid)). Close its window or use dechrome stop before launching another instance.")
            }
            try refuseLiveProfileLock()
            try profileImporter().recoverIfNeeded()
            if remoteDebuggingBlocked() {
                throw DCFailure("Chrome's RemoteDebuggingAllowed policy disables the command interface. DeChrome will not override workplace policies; ask your administrator whether this configuration is permitted.")
            }
            try validateResources()
            let prepared = try prepareUnlocked(force: false)
            let highWater = try profileVersion()
            if let highWater, Self.compareVersions(prepared.version, highWater.version) == .orderedAscending {
                throw DCFailure("This profile has been used by Chrome \(highWater.version), which is newer than the prepared browser \(prepared.version). Refresh from a newer installed Chrome instead of downgrading the profile.")
            }
            let target = url ?? (paths.resourcesURL.appendingPathComponent("Start.html").absoluteString + (tabs ? "?tabs=1" : ""))
            guard let parsed = URLComponents(string: target),
                  ["https", "http", "file", "chrome", "about"].contains(parsed.scheme?.lowercased() ?? ""),
                  !["https", "http"].contains(parsed.scheme?.lowercased() ?? "") || !(parsed.host ?? "").isEmpty else {
                throw DCFailure("Use an absolute https://, http://, file://, chrome://, or about: URL.")
            }
            let activePort = paths.profileURL.appendingPathComponent("DevToolsActivePort")
            if fm.fileExists(atPath: activePort.path) { try fm.removeItem(at: activePort) }
            let healthURL = paths.dataURL.appendingPathComponent("health.json")
            if fm.fileExists(atPath: healthURL.path) { try fm.removeItem(at: healthURL) }
            let launchID = UUID().uuidString
            let browser = paths.browserApp.appendingPathComponent("Contents/MacOS/Google Chrome")
            var env = environment.filter { !$0.key.hasPrefix("DYLD_") }
            env["DECHROME_ENABLED"] = "1"
            env["DECHROME_PROFILE_PATH"] = paths.profileURL.path
            env["DECHROME_LOG_PATH"] = paths.logsURL.appendingPathComponent("native.log").path
            env["DECHROME_DUMP_PATH"] = paths.logsURL.appendingPathComponent("view-tree.txt").path
            env["DECHROME_DIAGNOSTICS"] = diagnose ? "1" : "0"
            env["DECHROME_HEALTH_PATH"] = healthURL.path
            env["DECHROME_LAUNCH_ID"] = launchID
            env["DECHROME_TAB_MODE"] = tabs ? "1" : "0"
            env.removeValue(forKey: "DECHROME_LAUNCHER_APP")
            let launcherApp = paths.resourcesURL.deletingLastPathComponent().deletingLastPathComponent()
            if launcherApp.pathExtension == "app",
               fm.isExecutableFile(atPath: launcherApp.appendingPathComponent("Contents/MacOS/DeChrome").path) {
                env["DECHROME_LAUNCHER_APP"] = launcherApp.path
            }
            // A release launch must not inherit development-only frame changes.
            env.removeValue(forKey: "DECHROME_TOP_INSET")
            env.removeValue(forKey: "DECHROME_EXPERIMENTAL_CROP")
            env.removeValue(forKey: "DECHROME_INSPECT_ONLY")
            env.removeValue(forKey: "DECHROME_SELFTEST_RESIZE")
            if !stock { env["DYLD_INSERT_LIBRARIES"] = paths.resourcesURL.appendingPathComponent("DeChrome.dylib").path }
            let logURL = paths.logsURL.appendingPathComponent("chrome.log")
            if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            let output = try FileHandle(forWritingTo: logURL)
            try output.seekToEnd()
            defer { try? output.close() }
            let process = Process()
            process.executableURL = browser
            let importedDirectory = try profileImporter().validatedCurrentImport()?.sourceDirectory
            if let directory = importedDirectory,
               directory.isEmpty || directory == "." || directory == ".." ||
               directory.contains("/") || directory.contains("\\") || directory.contains("\0") {
                throw DCFailure("The imported Chrome profile directory is invalid. Open Profiles and sync to import it again.")
            }
            let profileArguments = importedDirectory.map { ["--profile-directory=\($0)"] } ?? []
            process.arguments = ["--user-data-dir=\(paths.profileURL.path)", "--no-first-run", "--no-default-browser-check",
                                 "--disable-sync", "--disable-background-mode", "--disable-component-update",
                                 "--remote-debugging-address=127.0.0.1", "--remote-debugging-port=0",
                                 "--window-size=960,720"] + profileArguments + (tabs ? ["--new-window", target] : ["--app=\(target)"])
            process.environment = env
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = output
            do { try process.run() }
            catch { throw DCFailure("macOS could not start the local Chrome copy: \(error.localizedDescription). See \(logURL.path).") }
            let state = DCProcessState(pid: process.processIdentifier, url: target, executable: browser.path,
                                       profile: paths.profileURL.path, startedAt: Date(),
                                       processBirth: processBirth(process.processIdentifier), browserVersion: prepared.version, stock: stock)
            do {
                try writeJSON(state, paths.stateURL)
                // Chrome may migrate its profile before its UI/debugger is ready.
                // Track this conservatively even if startup later fails.
                try writeJSON(DCProfileVersion(version: prepared.version), paths.dataURL.appendingPathComponent("profile-version.json"))
            } catch {
                terminateOwnChild(process)
                throw DCFailure("The browser was stopped because DeChrome could not safely record its process/profile version: \(error.localizedDescription)")
            }
            // Newly re-signed Chrome can wait before dyld while macOS assesses
            // it. Cold-copy assessment exceeded 20 seconds during testing.
            let deadline = Date().addingTimeInterval(90)
            while Date() < deadline {
                if !process.isRunning {
                    try? fm.removeItem(at: paths.stateURL)
                    throw DCFailure("Chrome exited during startup (status \(process.terminationStatus)). The installed Chrome or workplace controls may reject the locally signed copy. See \(logURL.path).")
                }
                if let port = debuggerPort(), loopbackPortIsListening(port),
                   stock || healthyWindow(healthURL, launchID: launchID) {
                    return state
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            // This is our new child; stop it without touching an unrelated PID.
            terminateOwnChild(process)
            if !process.isRunning { try? fm.removeItem(at: paths.stateURL) }
            let lastCheck = startupCommandError(healthURL, launchID: launchID)
            let detail = lastCheck.map { "\n\nLast startup check: \($0)" } ?? ""
            throw DCFailure("Chrome's content-only window and command interface did not become ready within 90 seconds.\(detail)\n\nRun Diagnostics in DeChrome, or dechrome doctor, and inspect \(paths.logsURL.path). You can also clear Enable tabs (experimental) and retry single-page mode. The browser profile has been preserved.")
        }
    }

    func stop() throws {
        try withOperationLock {
            guard let state = try status() else { return }
            // Re-check directly before signalling to reduce PID-reuse risk.
            guard try processMatches(state) else { throw DCFailure("The recorded process no longer matches DeChrome; it was not stopped.") }
            if Darwin.kill(state.pid, SIGTERM) != 0 { throw DCFailure("Could not stop DeChrome: \(String(cString: strerror(errno))).") }
            let deadline = Date().addingTimeInterval(8)
            var inspectionFailure: Error?
            while Date() < deadline {
                do {
                    if try !processMatches(state) {
                        try? fm.removeItem(at: paths.stateURL)
                        return
                    }
                } catch {
                    // macOS can briefly hide executable/argv information while
                    // a signalled process exits. Retry until exit is verified;
                    // a persistently uninspectable live PID still yields error.
                    inspectionFailure = error
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            if let inspectionFailure { throw inspectionFailure }
            throw DCFailure("DeChrome has not exited yet. Its process was not force-killed; close its window and retry.")
        }
    }

    func status() throws -> DCProcessState? {
        guard fm.fileExists(atPath: paths.stateURL.path) else { return nil }
        guard let state = readJSON(DCProcessState.self, paths.stateURL) else {
            throw DCFailure("DeChrome's process record is unreadable. No process will be stopped based on that record.")
        }
        return try processMatches(state) ? state : nil
    }

    func rollback() throws {
        try withOperationLock {
            try refuseRunningBrowser()
            let previousMetadata = paths.previousRoot.appendingPathComponent("prepared.json")
            guard let previous = readJSON(DCPrepared.self, previousMetadata),
                  fm.fileExists(atPath: paths.previousRoot.appendingPathComponent("Google Chrome.app/Contents/MacOS/Google Chrome").path) else {
                throw DCFailure("There is no previous prepared browser to restore.")
            }
            if let used = try profileVersion(),
               Self.compareVersions(previous.version, used.version) == .orderedAscending {
                throw DCFailure("Rollback would use Chrome \(previous.version) with a profile already opened by \(used.version). To protect that profile, DeChrome will not downgrade it. Refresh from an up-to-date installed Chrome instead.")
            }
            let temporary = paths.dataURL.appendingPathComponent("Browser.rollback-\(UUID().uuidString)", isDirectory: true)
            if fm.fileExists(atPath: paths.browserRoot.path) { try fm.moveItem(at: paths.browserRoot, to: temporary) }
            do { try fm.moveItem(at: paths.previousRoot, to: paths.browserRoot) }
            catch {
                if fm.fileExists(atPath: temporary.path) { try? fm.moveItem(at: temporary, to: paths.browserRoot) }
                throw error
            }
            if fm.fileExists(atPath: temporary.path) { try fm.moveItem(at: temporary, to: paths.previousRoot) }
        }
    }

    func doctor() -> [DCDiagnostic] {
        var checks: [DCDiagnostic] = []
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        checks.append(DCDiagnostic(level: "ok", name: "Processor", detail: "Apple Silicon (arm64)"))
        #else
        checks.append(DCDiagnostic(level: "error", name: "Processor", detail: "This release supports Apple Silicon only."))
        #endif
        checks.append(DCDiagnostic(level: os.majorVersion < 13 ? "error" : (os.majorVersion > 26 ? "warning" : "ok"), name: "macOS", detail: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion). Minimum deployment target: 13; runtime verification so far: macOS 26. macOS 27+ requires a compatibility test."))
        do {
            let version = try browserVersion(sourceChromeURL)
            checks.append(DCDiagnostic(level: "ok", name: "Installed Chrome", detail: "\(version) — \(sourceChromeURL.path)"))
            if let prepared = readJSON(DCPrepared.self, paths.metadataURL) {
                checks.append(DCDiagnostic(level: prepared.version == version ? "ok" : "warning", name: "Private Chrome", detail: "Prepared \(prepared.version); installed \(version). A newer installed version is refreshed on the next stopped launch."))
            } else {
                checks.append(DCDiagnostic(level: "warning", name: "Private Chrome", detail: "Not prepared yet. First launch creates and locally signs the private copy."))
            }
        } catch { checks.append(DCDiagnostic(level: "error", name: "Installed Chrome", detail: error.localizedDescription)) }
        do { try validateResources(); checks.append(DCDiagnostic(level: "ok", name: "App resources", detail: "Native shim and start page are present.")) }
        catch { checks.append(DCDiagnostic(level: "error", name: "App resources", detail: error.localizedDescription)) }
        checks.append(DCDiagnostic(level: remoteDebuggingBlocked() ? "error" : "ok", name: "Chrome debugging policy", detail: remoteDebuggingBlocked() ? "RemoteDebuggingAllowed is false. DeChrome will not override this policy." : "RemoteDebuggingAllowed is not explicitly disabled. Other managed policies can still restrict individual pages or locally signed apps."))
        if let availability = CFPreferencesCopyAppValue("DeveloperToolsAvailability" as CFString, "com.google.Chrome" as CFString) as? NSNumber, availability.intValue == 2 {
            checks.append(DCDiagnostic(level: "warning", name: "Developer Tools policy", detail: "DeveloperToolsAvailability is 2. The palette's CDP commands may be restricted by workplace policy."))
        }
        checks.append(DCDiagnostic(level: "warning", name: "Local signing", detail: "The private Chrome copy is ad-hoc signed with injection/library-validation exceptions. Signing or notarizing the launcher does not make that copy Google's official signed browser or grant workplace approval."))
        do {
            let running = try status()
            checks.append(DCDiagnostic(level: "ok", name: "Browser process", detail: running.map { "Running, PID \($0.pid), Chrome \($0.browserVersion)." } ?? "Stopped."))
        } catch { checks.append(DCDiagnostic(level: "error", name: "Browser process", detail: error.localizedDescription)) }
        if let lastCheck = startupCommandError(paths.dataURL.appendingPathComponent("health.json")) {
            checks.append(DCDiagnostic(level: "warning", name: "Last startup check", detail: lastCheck))
        }
        do {
            if let imported = try profileImporter().validatedCurrentImport() {
                checks.append(DCDiagnostic(level: "ok", name: "Imported Chrome profile",
                    detail: "\(imported.profileName) (\(imported.sourceDirectory)); copied from Chrome on \(ISO8601DateFormatter().string(from: imported.importedAt)). Update from Chrome replaces this separate DeChrome copy."))
            }
        } catch { checks.append(DCDiagnostic(level: "error", name: "Imported Chrome profile", detail: error.localizedDescription)) }
        do {
            if let used = try profileVersion() {
                checks.append(DCDiagnostic(level: "ok", name: "Profile version", detail: "Highest launched Chrome version: \(used.version). Older versions will not be launched against this profile."))
            }
        } catch { checks.append(DCDiagnostic(level: "error", name: "Profile version", detail: error.localizedDescription)) }
        checks.append(DCDiagnostic(level: "ok", name: "Storage", detail: "Data: \(paths.dataURL.path)\nLogs: \(paths.logsURL.path)"))
        return checks
    }

    private func prepareUnlocked(force: Bool) throws -> DCPreparation {
        try refuseRunningBrowser()
        // A process can be interrupted between the two directory renames.
        // Restore the last complete directory before attempting another update.
        if !fm.fileExists(atPath: paths.browserRoot.path),
           fm.fileExists(atPath: paths.previousRoot.appendingPathComponent("prepared.json").path) {
            try refuseSymlink(paths.previousRoot)
            _ = try browserVersion(paths.previousRoot.appendingPathComponent("Google Chrome.app"))
            try fm.moveItem(at: paths.previousRoot, to: paths.browserRoot)
        }
        let version = try browserVersion(sourceChromeURL)
        let previous = readJSON(DCPrepared.self, paths.metadataURL)
        let existingVersion = previous?.version ?? (try? browserVersion(paths.browserApp))
        if let existingVersion, Self.compareVersions(version, existingVersion) == .orderedAscending {
            throw DCFailure("Installed Chrome \(version) is older than DeChrome's prepared \(existingVersion). The private browser was preserved; install an up-to-date Chrome before refreshing.")
        }
        let binary = paths.browserApp.appendingPathComponent("Contents/MacOS/Google Chrome")
        if !force, let previous, previous.version == version,
           previous.sourcePath == sourceChromeURL.path, fm.isExecutableFile(atPath: binary.path) {
            return DCPreparation(changed: false, previousVersion: previous.version, version: version, browserPath: paths.browserApp.path)
        }
        guard !sourceChromeURL.resolvingSymlinksInPath().path.hasPrefix(paths.dataURL.resolvingSymlinksInPath().path + "/") else {
            throw DCFailure("The source Chrome must be an independent installed application, outside DeChrome's data directory.")
        }
        let stage = paths.dataURL.appendingPathComponent("Browser.staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        let stagedApp = stage.appendingPathComponent("Google Chrome.app", isDirectory: true)
        let copied = try command("/bin/cp", ["-cR", sourceChromeURL.path, stagedApp.path], requireSuccess: false)
        if copied.status != 0 {
            if fm.fileExists(atPath: stagedApp.path) { try fm.removeItem(at: stagedApp) }
            try command("/usr/bin/ditto", [sourceChromeURL.path, stagedApp.path])
        }
        for attribute in ["com.apple.FinderInfo", "com.apple.ResourceFork"] {
            _ = try command("/usr/bin/xattr", ["-dr", attribute, stagedApp.path], requireSuccess: false)
        }
        let infoURL = stagedApp.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: infoURL)
        guard var info = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw DCFailure("The installed Chrome Info.plist could not be read.")
        }
        for key in Array(info.keys) where key.hasPrefix("KS") { info.removeValue(forKey: key) }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL, options: .atomic)
        let entitlements = stage.appendingPathComponent("browser-entitlements.plist")
        let exceptions = ["com.apple.security.cs.allow-dyld-environment-variables": true,
                          "com.apple.security.cs.disable-library-validation": true]
        try PropertyListSerialization.data(fromPropertyList: exceptions, format: .xml, options: 0).write(to: entitlements)
        try command("/usr/bin/codesign", ["--force", "--sign", "-", "--options", "runtime", "--timestamp=none", "--entitlements", entitlements.path, stagedApp.path])
        try command("/usr/bin/codesign", ["--verify", "--strict", stagedApp.appendingPathComponent("Contents/MacOS/Google Chrome").path])
        guard try browserVersion(sourceChromeURL) == version, try browserVersion(stagedApp) == version else {
            throw DCFailure("Installed Chrome changed while its private copy was being prepared. The previous copy was preserved; retry once Chrome finishes updating.")
        }
        try writeJSON(DCPrepared(version: version, sourcePath: sourceChromeURL.path, preparedAt: Date()), stage.appendingPathComponent("prepared.json"))
        try refuseRunningBrowser()
        try refuseSymlink(paths.browserRoot)
        try refuseSymlink(paths.previousRoot)
        if fm.fileExists(atPath: paths.previousRoot.path) { try fm.removeItem(at: paths.previousRoot) }
        let hadCurrent = fm.fileExists(atPath: paths.browserRoot.path)
        if hadCurrent { try fm.moveItem(at: paths.browserRoot, to: paths.previousRoot) }
        do { try fm.moveItem(at: stage, to: paths.browserRoot) }
        catch {
            if hadCurrent { try? fm.moveItem(at: paths.previousRoot, to: paths.browserRoot) }
            throw DCFailure("The prepared browser could not be activated. The previous copy was restored where possible: \(error.localizedDescription)")
        }
        return DCPreparation(changed: true, previousVersion: existingVersion, version: version, browserPath: paths.browserApp.path)
    }

    private func withOperationLock<T>(_ operation: () throws -> T) throws -> T {
        try validateImportSourceLocation(profileImporter().sourceRoot)
        try ensureDirectories()
        let descriptor = Darwin.open(paths.lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw DCFailure("Could not open DeChrome's operation lock: \(String(cString: strerror(errno))).") }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw DCFailure("Another DeChrome setup, refresh, or launch operation is already running. Retry when it finishes.") }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    // Check before directory creation or chmod: an import source must never be
    // inside, or contain, a directory that DeChrome owns and may replace.
    private func validateImportSourceLocation(_ sourceRoot: URL) throws {
        func canonical(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
        let source = canonical(sourceRoot)
        for managed in [paths.dataURL, paths.logsURL] {
            let destination = canonical(managed)
            if source == destination || source.hasPrefix(destination + "/") || destination.hasPrefix(source + "/") {
                throw DCFailure("Chrome's source data folder must be separate from DeChrome's data, backups, and logs. No profile files were changed.")
            }
        }
    }

    private func ensureDirectories() throws {
        guard paths.dataURL.pathComponents.count >= 3, paths.dataURL.path != paths.resourcesURL.path else {
            throw DCFailure("DeChrome's data directory must be a separate user-owned directory.")
        }
        for directory in [paths.dataURL, paths.logsURL, paths.profileURL] {
            try refuseSymlink(directory)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }

    private func refuseSymlink(_ url: URL) throws {
        if (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil {
            throw DCFailure("Refusing to modify a symbolic link at \(url.path).")
        }
    }

    private func refuseRunningBrowser() throws {
        if let running = try status() { throw DCFailure("Chrome is running under DeChrome (PID \(running.pid)). Stop it before preparing, refreshing, or rolling back its files.") }
        try refuseLiveProfileLock()
    }

    private func refuseLiveProfileLock() throws {
        let singleton = paths.profileURL.appendingPathComponent("SingletonLock")
        if let destination = try? fm.destinationOfSymbolicLink(atPath: singleton.path),
           let tail = destination.split(separator: "-").last, let pid = Int32(tail), pid > 0,
           Darwin.kill(pid, 0) == 0 || errno == EPERM {
            throw DCFailure("The private Chrome profile is locked by process \(pid). Close that browser before continuing; DeChrome will not remove a live profile lock.")
        }
        // Chrome's lock representation can change, or a process record can be
        // lost. Inspect actual browser processes as well before touching files.
        let listing = try command("/bin/ps", ["-ww", "-axo", "pid=,command="], requireSuccess: false)
        guard listing.status == 0 else {
            throw DCFailure("DeChrome could not inspect running browser processes, so it will not modify or reopen the private profile. Try from a normal Terminal session; workplace controls may restrict process inspection.")
        }
        for line in listing.output.split(whereSeparator: \.isNewline) where line.contains("--user-data-dir") {
            guard let pidText = line.split(whereSeparator: \.isWhitespace).first,
                  let pid = Int32(pidText), pid > 1 else { continue }
            guard let executable = processExecutable(pid) else {
                if commandUsesProfile(String(line)), Darwin.kill(pid, 0) == 0 || errno == EPERM {
                    throw DCFailure("Process \(pid) references DeChrome's private profile, but macOS did not allow its executable to be inspected. The profile and browser files were preserved.")
                }
                continue
            }
            guard executable.hasSuffix("/Google Chrome.app/Contents/MacOS/Google Chrome") else { continue }
            guard let arguments = processArguments(pid) else {
                if processIsLive(pid) {
                    throw DCFailure("macOS did not allow Chrome process \(pid)'s arguments to be inspected. DeChrome cannot safely determine whether it owns the private profile, so browser and profile files were preserved.")
                }
                continue
            }
            guard argumentsUseProfile(arguments) else { continue }
            throw DCFailure("Chrome process \(pid) is already using DeChrome's private profile. Close it before setup or launch; its files and profile were not changed.")
        }
    }

    private func processMatches(_ state: DCProcessState) throws -> Bool {
        guard state.pid > 1,
              sameExistingFile(state.executable, paths.browserApp.appendingPathComponent("Contents/MacOS/Google Chrome").path),
              sameExistingFile(state.profile, paths.profileURL.path) else { return false }
        guard let executable = processExecutable(state.pid) else {
            if processIsLive(state.pid) {
                throw DCFailure("The recorded browser process \(state.pid) is alive, but macOS did not allow its executable to be inspected. DeChrome will not report it stopped or signal an unverified process.")
            }
            return false
        }
        guard sameExistingFile(executable, state.executable) else { return false }
        guard let arguments = processArguments(state.pid) else {
            if processIsLive(state.pid) {
                throw DCFailure("The recorded browser process \(state.pid) is alive, but macOS did not allow its arguments to be inspected. DeChrome will not report it stopped or signal an unverified process.")
            }
            return false
        }
        guard argumentsUseProfile(arguments) else { return false }
        let birth = processBirth(state.pid)
        if birth.isEmpty || state.processBirth.isEmpty {
            if processIsLive(state.pid) {
                throw DCFailure("The recorded browser process \(state.pid) is alive, but its start time cannot be verified. DeChrome will not report it stopped or signal an unverified process.")
            }
            return false
        }
        return !state.processBirth.isEmpty && birth == state.processBirth
    }

    private func processBirth(_ pid: Int32) -> String {
        (try? command("/bin/ps", ["-p", String(pid), "-o", "lstart="], requireSuccess: false).output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
    }

    private func processExecutable(_ pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let length = buffer.withUnsafeMutableBytes { raw -> Int32 in
            guard let address = raw.baseAddress else { return 0 }
            return dc_proc_pidpath(pid, address, UInt32(raw.count))
        }
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }

    private func commandUsesProfile(_ command: String) -> Bool {
        let recorded = readJSON(DCProcessState.self, paths.stateURL)?.profile
        let spellings = [paths.profileURL.path, recorded].compactMap { $0 }
        for spelling in spellings {
            guard sameExistingFile(spelling, paths.profileURL.path),
                  let match = command.range(of: "--user-data-dir=\(spelling)") else { continue }
            let suffix = command[match.upperBound...]
            if suffix.isEmpty || suffix.first?.isWhitespace == true || suffix.first == "\"" || suffix.first == "'" { return true }
        }
        return false
    }

    // URL.standardizedFileURL can change /private/tmp to /tmp after a path is
    // created. Identity is the existing filesystem object, never its spelling.
    private func sameExistingFile(_ lhs: String, _ rhs: String) -> Bool {
        let leftPath = URL(fileURLWithPath: lhs).resolvingSymlinksInPath().path
        let rightPath = URL(fileURLWithPath: rhs).resolvingSymlinksInPath().path
        guard let left = try? fm.attributesOfItem(atPath: leftPath),
              let right = try? fm.attributesOfItem(atPath: rightPath),
              let leftDevice = left[.systemNumber] as? NSNumber,
              let rightDevice = right[.systemNumber] as? NSNumber,
              let leftInode = left[.systemFileNumber] as? NSNumber,
              let rightInode = right[.systemFileNumber] as? NSNumber else { return false }
        return leftDevice == rightDevice && leftInode == rightInode
    }

    private func argumentsUseProfile(_ arguments: [String]) -> Bool {
        for (index, argument) in arguments.enumerated() {
            if argument.hasPrefix("--user-data-dir=") {
                return sameExistingFile(String(argument.dropFirst("--user-data-dir=".count)), paths.profileURL.path)
            }
            if argument == "--user-data-dir", index + 1 < arguments.count {
                return sameExistingFile(arguments[index + 1], paths.profileURL.path)
            }
        }
        return false
    }

    private func processIsLive(_ pid: Int32) -> Bool {
        if Darwin.kill(pid, 0) != 0 && errno == ESRCH { return false }
        // A process can briefly remain as a zombie after SIGTERM. That is an
        // exited browser awaiting its parent's reap, not an inspection denial.
        if let status = try? command("/bin/ps", ["-p", String(pid), "-o", "stat="], requireSuccess: false),
           status.status == 0,
           status.output.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Z") { return false }
        // It may have exited between kill(0) and the process-table query.
        if Darwin.kill(pid, 0) != 0 && errno == ESRCH { return false }
        return true
    }

    private func processArguments(_ pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var count = 0
        guard mib.withUnsafeMutableBufferPointer({ dc_sysctl($0.baseAddress!, UInt32($0.count), nil, &count, nil, 0) }) == 0,
              count > MemoryLayout<Int32>.size, count <= 4 * 1024 * 1024 else { return nil }
        var bytes = [UInt8](repeating: 0, count: count)
        let result = mib.withUnsafeMutableBufferPointer { mibBuffer in
            bytes.withUnsafeMutableBytes { dc_sysctl(mibBuffer.baseAddress!, UInt32(mibBuffer.count), $0.baseAddress, &count, nil, 0) }
        }
        guard result == 0 else { return nil }
        var argumentCount: Int32 = 0
        withUnsafeMutableBytes(of: &argumentCount) { destination in
            destination.copyBytes(from: bytes.prefix(MemoryLayout<Int32>.size))
        }
        guard argumentCount > 0, argumentCount < 131_072 else { return nil }
        var cursor = MemoryLayout<Int32>.size
        // Skip the executable path and the padding before argv[0].
        while cursor < count && bytes[cursor] != 0 { cursor += 1 }
        while cursor < count && bytes[cursor] == 0 { cursor += 1 }
        var arguments: [String] = []
        for _ in 0..<argumentCount {
            let start = cursor
            while cursor < count && bytes[cursor] != 0 { cursor += 1 }
            guard cursor < count, let argument = String(bytes: bytes[start..<cursor], encoding: .utf8) else { return nil }
            arguments.append(argument)
            cursor += 1
        }
        return arguments
    }

    private func validateResources() throws {
        guard fm.fileExists(atPath: paths.resourcesURL.appendingPathComponent("DeChrome.dylib").path),
              fm.fileExists(atPath: paths.resourcesURL.appendingPathComponent("Start.html").path) else {
            throw DCFailure("DeChrome's bundled native library or start page is missing. Reinstall the complete DeChrome.app.")
        }
    }

    private func browserVersion(_ app: URL) throws -> String {
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let info = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String,
              version.range(of: "^[0-9]+(?:\\.[0-9]+)*$", options: .regularExpression) != nil,
              fm.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/Google Chrome").path) else {
            throw DCFailure("Google Chrome was not found as a complete installed application at \(app.path). Install Chrome normally, or set DECHROME_CHROME_PATH to its app bundle.")
        }
        if let minimum = info["LSMinimumSystemVersion"] as? String {
            let host = ProcessInfo.processInfo.operatingSystemVersion
            let current = "\(host.majorVersion).\(host.minorVersion).\(host.patchVersion)"
            if Self.compareVersions(current, minimum) == .orderedAscending {
                throw DCFailure("Installed Chrome requires macOS \(minimum), but this Mac runs \(current).")
            }
        }
        return version
    }

    private func remoteDebuggingBlocked() -> Bool {
        (CFPreferencesCopyAppValue("RemoteDebuggingAllowed" as CFString, "com.google.Chrome" as CFString) as? NSNumber)?.boolValue == false
    }

    private func profileVersion() throws -> DCProfileVersion? {
        let file = paths.dataURL.appendingPathComponent("profile-version.json")
        guard fm.fileExists(atPath: file.path) else { return nil }
        guard let version = readJSON(DCProfileVersion.self, file),
              version.version.range(of: "^[0-9]+(?:\\.[0-9]+)*$", options: .regularExpression) != nil else {
            throw DCFailure("The private profile's browser-version record is unreadable. DeChrome will not risk opening that profile with an older browser; preserve the profile and repair its version record before continuing.")
        }
        return version
    }

    private func terminateOwnChild(_ process: Process) {
        if process.isRunning { process.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    }

    private func debuggerPort() -> UInt16? {
        guard let text = try? String(contentsOf: paths.profileURL.appendingPathComponent("DevToolsActivePort"), encoding: .utf8),
              let first = text.split(whereSeparator: \.isNewline).first, let port = UInt16(first), port > 0 else { return nil }
        return port
    }

    private func loopbackPortIsListening(_ port: UInt16) -> Bool {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private func startupCommandError(_ file: URL, launchID: String? = nil) -> String? {
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              launchID == nil || object["launchID"] as? String == launchID,
              object["commandInterfaceReady"] as? Bool == false,
              let error = object["commandError"] as? String, !error.isEmpty else { return nil }
        return error
    }

    private func healthyWindow(_ file: URL, launchID: String) -> Bool {
        guard let data = try? Data(contentsOf: file), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["launchID"] as? String == launchID, object["configured"] as? Bool == true,
              object["commandInterfaceReady"] as? Bool == true,
              object["role"] as? String == "AXWindow", object["subrole"] as? String == "AXStandardWindow",
              let frame = object["frame"] as? [String: Double], let content = object["content"] as? [String: Double],
              let renderer = object["renderer"] as? [String: Double],
              let width = frame["width"], let height = frame["height"], width >= 100, height >= 100 else { return false }
        return [content, renderer].allSatisfy { abs(($0["width"] ?? -1000) - width) <= 1 && abs(($0["height"] ?? -1000) - height) <= 1 }
    }

    @discardableResult private func command(_ executable: String, _ arguments: [String], requireSuccess: Bool = true) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = environment
        env["LC_ALL"] = "C"
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        if requireSuccess && process.terminationStatus != 0 {
            throw DCFailure("\(URL(fileURLWithPath: executable).lastPathComponent) failed (\(process.terminationStatus)): \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return (process.terminationStatus, text)
    }

    private func readJSON<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private func writeJSON<T: Encodable>(_ value: T, _ url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x < y { return .orderedAscending }
            if x > y { return .orderedDescending }
        }
        return .orderedSame
    }
}
