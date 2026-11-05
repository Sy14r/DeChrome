import AppKit
import Foundation
import Darwin

private enum DCCommandError: LocalizedError {
    case usage(String)
    var errorDescription: String? {
        switch self { case .usage(let message): return message }
    }
}

private func dcResourcesURL() -> URL {
    if let override = ProcessInfo.processInfo.environment["DECHROME_RESOURCES_DIR"], !override.isEmpty {
        return URL(fileURLWithPath: override, isDirectory: true)
    }
    return Bundle.main.resourceURL ?? Bundle.main.bundleURL
}

private func dcVersion() -> String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.0"
}

private func dcTabsByDefault() -> Bool {
    if let preference = UserDefaults.standard.object(forKey: "experimentalTabsEnabled") as? Bool { return preference }
    return Bundle.main.object(forInfoDictionaryKey: "DeChromeExperimentalTabs") as? Bool ?? false
}

private func dcJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

private func dcDiagnosticsText(_ diagnostics: [DCDiagnostic]) -> String {
    diagnostics.map { "[\($0.level.uppercased())] \($0.name)\n\($0.detail)" }.joined(separator: "\n\n")
}

private let dcUsage = """
DeChrome — content-only Google Chrome with a native command palette

Usage:
  dechrome launch [URL] [--tabs|--single-page] [--diagnose] [--stock] [--json]
  dechrome prepare [--json]
  dechrome refresh [--json]
  dechrome stop
  dechrome status [--json]
  dechrome doctor [--json]
  dechrome rollback
  dechrome profiles [--source-root PATH] [--json]
  dechrome import-profile DIRECTORY [--source-root PATH] [--json]
  dechrome sync-profile [--json]
  dechrome profiles-ui
  dechrome version
  dechrome help

Launch automatically refreshes the private browser when installed Chrome changes.
Chrome profiles and logs are stored separately from this application.
This preview enables hidden tabs by default. --single-page uses the 0.1 app-window mode.
Profile import and sync copy from Chrome to DeChrome. Quit both browsers before copying.
Updating replaces the DeChrome copy and keeps its previous copy for recovery.
"""

private func dcProfileArguments(_ arguments: [String], directoryRequired: Bool) throws -> (String?, URL?) {
    var positional: [String] = []
    var sourceRoot: URL?
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "--source-root" {
            guard sourceRoot == nil, index + 1 < arguments.count else {
                throw DCCommandError.usage("Use --source-root once, followed by the Chrome data folder path.")
            }
            let path = (arguments[index + 1] as NSString).expandingTildeInPath
            guard path.hasPrefix("/") else { throw DCCommandError.usage("Use an absolute Chrome data folder path.") }
            sourceRoot = URL(fileURLWithPath: path, isDirectory: true)
            index += 2
        } else {
            guard !argument.hasPrefix("--") else { throw DCCommandError.usage("Unknown option: \(argument)") }
            positional.append(argument)
            index += 1
        }
    }
    guard positional.count == (directoryRequired ? 1 : 0) else {
        throw DCCommandError.usage(directoryRequired ?
            "Choose one profile directory, such as Default or 'Profile 1'. Run dechrome profiles to list them." :
            "Unexpected profile command argument.")
    }
    return (positional.first, sourceRoot)
}

private func dcRunCLI(_ arguments: [String]) throws -> Int32 {
    let json = arguments.contains("--json")
    let args = arguments.filter { $0 != "--json" }
    guard let command = args.first else { print(dcUsage); return 0 }
    let rest = Array(args.dropFirst())
    if command == "help" || command == "--help" || command == "-h" {
        print(dcUsage)
        return 0
    }
    if command == "version" || command == "--version" {
        print("DeChrome \(dcVersion())")
        return 0
    }
    let runtime = DeChromeRuntime(resourcesURL: dcResourcesURL())
    switch command {
    case "launch":
        let knownFlags: Set<String> = ["--diagnose", "--stock", "--tabs", "--single-page"]
        let unknown = rest.filter { $0.hasPrefix("--") && !knownFlags.contains($0) }
        guard unknown.isEmpty else { throw DCCommandError.usage("Unknown option: \(unknown[0])\n\n\(dcUsage)") }
        guard !(rest.contains("--tabs") && rest.contains("--single-page")) else {
            throw DCCommandError.usage("Choose either --tabs or --single-page.")
        }
        let urls = rest.filter { !$0.hasPrefix("--") }
        guard urls.count <= 1 else { throw DCCommandError.usage("Use one initial URL.\n\n\(dcUsage)") }
        let tabMode = rest.contains("--tabs") || (!rest.contains("--single-page") && dcTabsByDefault())
        let state = try runtime.launch(url: urls.first, diagnose: rest.contains("--diagnose"), stock: rest.contains("--stock"), tabs: tabMode)
        if json { print(try dcJSON(state)) }
        else {
            print("\(state.stock ? "Baseline Chrome" : "DeChrome") is running (PID \(state.pid), Chrome \(state.browserVersion)).")
            if !state.stock { print("Press ⌘K to navigate or run a command.") }
        }
    case "prepare", "refresh":
        guard rest.isEmpty else { throw DCCommandError.usage("Unexpected option for \(command).") }
        let result = try runtime.prepare(force: command == "refresh")
        if json { print(try dcJSON(result)) }
        else { print(result.changed ? "Prepared Chrome \(result.version)." : "Chrome \(result.version) is ready.") }
    case "stop":
        guard rest.isEmpty else { throw DCCommandError.usage("Unexpected option for stop.") }
        try runtime.stop()
        print("DeChrome browser stopped.")
    case "status":
        guard rest.isEmpty else { throw DCCommandError.usage("Unexpected option for status.") }
        let state = try runtime.status()
        if json { print(try dcJSON(state)) }
        else if let state = state { print("Running: PID \(state.pid)\nChrome: \(state.browserVersion)\nPage: \(state.url)") }
        else { print("DeChrome is not running.") }
    case "doctor":
        guard rest.isEmpty else { throw DCCommandError.usage("Unexpected option for doctor.") }
        let diagnostics = runtime.doctor()
        print(json ? try dcJSON(diagnostics) : dcDiagnosticsText(diagnostics))
        return diagnostics.contains { $0.level == "error" } ? 1 : 0
    case "rollback":
        guard rest.isEmpty else { throw DCCommandError.usage("Unexpected option for rollback.") }
        try runtime.rollback()
        print("Restored the previous prepared browser.")
    case "profiles":
        let (_, sourceRoot) = try dcProfileArguments(rest, directoryRequired: false)
        let profiles = try runtime.availableChromeProfiles(sourceRoot: sourceRoot)
        if json { print(try dcJSON(profiles)) }
        else if profiles.isEmpty { print("No Chrome profiles were found in that data folder.") }
        else {
            for profile in profiles {
                let account = profile.userName.map { " — \($0)" } ?? ""
                print("\(profile.directory): \(profile.name)\(account)")
            }
        }
    case "import-profile":
        let (directory, sourceRoot) = try dcProfileArguments(rest, directoryRequired: true)
        let state = try runtime.importChromeProfile(directory: directory!, sourceRoot: sourceRoot)
        if json { print(try dcJSON(state)) }
        else { print("Imported \(state.profileName) into DeChrome. The previous DeChrome copy is kept for recovery.") }
    case "sync-profile":
        guard rest.isEmpty else { throw DCCommandError.usage("Unexpected option for sync-profile.") }
        let state = try runtime.refreshChromeProfile()
        if json { print(try dcJSON(state)) }
        else { print("Updated DeChrome from \(state.profileName). The previous DeChrome copy is kept for recovery.") }
    default:
        throw DCCommandError.usage("Unknown command: \(command)\n\n\(dcUsage)")
    }
    return 0
}

private final class DCAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let runtime = DeChromeRuntime(resourcesURL: dcResourcesURL())
    private let worker = DispatchQueue(label: "local.dechrome.launcher", qos: .userInitiated)
    private var window: NSWindow!
    private var address: NSTextField!
    private var statusLabel: NSTextField!
    private var progress: NSProgressIndicator!
    private var openButton: NSButton!
    private var refreshButton: NSButton!
    private var diagnosticsButton: NSButton!
    private var profilesButton: NSButton!
    private var tabsCheckbox: NSButton!
    private var busy = false
    private var profileBusy = false
    private var pendingURL: String?
    private let manageProfilesAtLaunch: Bool
    private var profileManager: DCProfileManagerController?

    init(manageProfilesAtLaunch: Bool = false) {
        self.manageProfilesAtLaunch = manageProfilesAtLaunch
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        if manageProfilesAtLaunch {
            window.orderOut(nil)
            showProfiles()
        } else {
            // Finder can deliver an initial Open URL event during launch. Give it
            // one main-loop turn to populate the address before starting setup.
            DispatchQueue.main.async { self.launchBrowser() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !busy && !profileBusy }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        profileBusy ? .terminateCancel : .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if manageProfilesAtLaunch || profileManager?.isVisible == true { showProfiles() }
        else if !busy && !profileBusy && window != nil && window.attachedSheet == nil { launchBrowser() }
        else { window?.makeKeyAndOrderFront(nil) }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, ["https", "http", "file", "chrome"].contains(url.scheme?.lowercased() ?? "") else { return }
        pendingURL = url.absoluteString
        if address != nil { address.stringValue = pendingURL ?? "" }
        if window != nil && !busy && window.attachedSheet == nil { launchBrowser() }
    }

    private func buildMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "DeChrome")
        appMenu.addItem(withTitle: "About DeChrome", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit DeChrome", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open Browser", action: #selector(openBrowser), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Refresh Chrome", action: #selector(refreshChrome), keyEquivalent: "")
        fileMenu.addItem(withTitle: "Profiles and sync…", action: #selector(showProfiles), keyEquivalent: "")
        fileMenu.addItem(withTitle: "Diagnostics…", action: #selector(showDiagnostics), keyEquivalent: "")
        fileMenu.addItem(withTitle: "Open Logs", action: #selector(openLogs), keyEquivalent: "")
        fileItem.submenu = fileMenu
        menu.addItem(fileItem)
        NSApp.mainMenu = menu
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 350),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "DeChrome"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        guard let content = window.contentView else { return }
        let title = NSTextField(labelWithString: "DeChrome")
        title.font = .systemFont(ofSize: 26, weight: .semibold)
        title.frame = NSRect(x: 28, y: 290, width: 464, height: 34)
        content.addSubview(title)
        let description = NSTextField(wrappingLabelWithString: dcTabsByDefault() ?
            "Chrome with just your pages. Use ⌘T for a new tab and ⌘K to switch tabs or navigate." :
            "Chrome with just your page. Use ⌘K to navigate and run browser commands.")
        description.textColor = .secondaryLabelColor
        description.frame = NSRect(x: 28, y: 238, width: 464, height: 44)
        content.addSubview(description)
        address = NSTextField(string: pendingURL ?? "")
        address.placeholderString = "Starting page URL (optional)"
        address.font = .systemFont(ofSize: 14)
        address.frame = NSRect(x: 28, y: 194, width: 464, height: 28)
        address.target = self
        address.action = #selector(openBrowser)
        content.addSubview(address)
        tabsCheckbox = NSButton(checkboxWithTitle: "Enable tabs (experimental)", target: self, action: #selector(toggleTabs))
        tabsCheckbox.state = dcTabsByDefault() ? .on : .off
        tabsCheckbox.frame = NSRect(x: 28, y: 158, width: 464, height: 22)
        content.addSubview(tabsCheckbox)
        progress = NSProgressIndicator(frame: NSRect(x: 28, y: 127, width: 18, height: 18))
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        content.addSubview(progress)
        statusLabel = NSTextField(wrappingLabelWithString: "Preparing your browser…")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.frame = NSRect(x: 56, y: 108, width: 436, height: 42)
        content.addSubview(statusLabel)
        openButton = NSButton(title: "Open Browser", target: self, action: #selector(openBrowser))
        openButton.bezelStyle = .rounded
        openButton.keyEquivalent = "\r"
        openButton.frame = NSRect(x: 358, y: 32, width: 140, height: 32)
        content.addSubview(openButton)
        refreshButton = NSButton(title: "Refresh Chrome", target: self, action: #selector(refreshChrome))
        refreshButton.bezelStyle = .rounded
        refreshButton.frame = NSRect(x: 22, y: 32, width: 140, height: 32)
        content.addSubview(refreshButton)
        diagnosticsButton = NSButton(title: "Diagnostics…", target: self, action: #selector(showDiagnostics))
        diagnosticsButton.bezelStyle = .rounded
        diagnosticsButton.frame = NSRect(x: 160, y: 32, width: 140, height: 32)
        content.addSubview(diagnosticsButton)
        profilesButton = NSButton(title: "Profiles and sync…", target: self, action: #selector(showProfiles))
        profilesButton.bezelStyle = .rounded
        profilesButton.frame = NSRect(x: 22, y: 72, width: 200, height: 32)
        content.addSubview(profilesButton)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setBusy(_ value: Bool, message: String) {
        busy = value
        updateActionAvailability()
        statusLabel.stringValue = message
        statusLabel.textColor = .secondaryLabelColor
        if value { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
    }

    private func updateActionAvailability() {
        let available = !busy && !profileBusy
        address?.isEnabled = available
        openButton?.isEnabled = available
        refreshButton?.isEnabled = available
        diagnosticsButton?.isEnabled = available
        tabsCheckbox?.isEnabled = available
        profilesButton?.isEnabled = available
    }

    private func showError(_ error: Error) {
        setBusy(false, message: error.localizedDescription)
        statusLabel.textColor = .systemRed
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "DeChrome couldn’t complete that action"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Logs")
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn { self.openLogs() }
        }
    }

    private func launchBrowser() {
        guard !busy && !profileBusy && window.attachedSheet == nil else { return }
        let typed = address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = typed.isEmpty ? pendingURL : typed
        let useTabs = tabsCheckbox.state == .on
        pendingURL = nil
        setBusy(true, message: "Opening your browser… First launch can take up to 90 seconds.")
        worker.async {
            do {
                let existing = try self.runtime.status()
                let state: DCProcessState
                if let existing = existing { state = existing }
                else { state = try self.runtime.launch(url: url, tabs: useTabs) }
                DispatchQueue.main.async {
                    self.setBusy(false, message: "Your browser is ready.")
                    let deferredURL = self.pendingURL
                    self.pendingURL = nil
                    let requestedURL = deferredURL ?? url
                    // Never discard an address delivered while setup was in
                    // progress, or pretend an existing page was navigated.
                    let needsNavigation = existing != nil ? requestedURL != nil :
                        (deferredURL != nil && deferredURL != state.url)
                    if needsNavigation, let requestedURL = requestedURL {
                        self.explainExistingBrowser(state, requestedURL: requestedURL)
                    } else { self.focusBrowserAndFinish(state) }
                }
            } catch { DispatchQueue.main.async { self.showError(error) } }
        }
    }

    private func explainExistingBrowser(_ state: DCProcessState, requestedURL: String) {
        statusLabel.stringValue = "Chrome is already open. Use ⌘K or ⌘L to navigate."
        let alert = NSAlert()
        alert.messageText = "Your DeChrome browser is already open"
        alert.informativeText = "Use ⌘K or ⌘L in its window to open this address:\n\n\(requestedURL)\n\nThe existing page has not been changed."
        alert.addButton(withTitle: "Open Chrome")
        alert.addButton(withTitle: "Keep Launcher Open")
        alert.beginSheetModal(for: window) { response in
            if self.pendingURL != nil { self.launchBrowser() }
            else if response == .alertFirstButtonReturn { self.focusBrowserAndFinish(state) }
        }
    }

    private func focusBrowserAndFinish(_ state: DCProcessState) {
        // Runtime status validates PID, executable, profile, and process birth.
        // Check AppKit's executable too before activating that exact process.
        guard let application = NSRunningApplication(processIdentifier: state.pid),
              application.executableURL?.resolvingSymlinksInPath().path ==
                URL(fileURLWithPath: state.executable).resolvingSymlinksInPath().path else {
            showError(DCFailure("The DeChrome browser has closed. Choose Open Browser to start it again."))
            return
        }
        let activated: Bool
        if #available(macOS 14.0, *) { activated = application.activate() }
        else { activated = application.activate(options: [.activateIgnoringOtherApps]) }
        guard activated else {
            showError(DCFailure("Chrome is running, but macOS could not bring its window forward. Switch to its window in AeroSpace."))
            return
        }
        window.orderOut(nil)
        // The Chrome process is independent; the launcher need not leave a
        // second Dock icon or setup window behind it.
        NSApp.terminate(nil)
    }

    @objc private func openBrowser() { launchBrowser() }

    @objc private func toggleTabs() {
        UserDefaults.standard.set(tabsCheckbox.state == .on, forKey: "experimentalTabsEnabled")
    }

    @objc private func refreshChrome() {
        guard !busy && !profileBusy && window.attachedSheet == nil else { return }
        setBusy(true, message: "Refreshing the private Chrome copy…")
        worker.async {
            do {
                let result = try self.runtime.prepare(force: true)
                DispatchQueue.main.async { self.setBusy(false, message: "Chrome \(result.version) is ready. Open Browser to continue.") }
            } catch { DispatchQueue.main.async { self.showError(error) } }
        }
    }

    @objc private func showDiagnostics() {
        guard !busy && !profileBusy && window.attachedSheet == nil else { return }
        setBusy(true, message: "Checking this Mac…")
        worker.async {
            let text = dcDiagnosticsText(self.runtime.doctor())
            DispatchQueue.main.async {
                self.setBusy(false, message: "Diagnostics complete.")
                let alert = NSAlert()
                alert.messageText = "DeChrome diagnostics"
                alert.informativeText = "Compatibility and browser setup on this Mac."
                alert.addButton(withTitle: "Done")
                alert.addButton(withTitle: "Open Logs")
                let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 300))
                scroll.hasVerticalScroller = true
                let textView = NSTextView(frame: scroll.bounds)
                textView.isEditable = false
                textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                textView.string = text
                textView.autoresizingMask = [.width]
                textView.isVerticallyResizable = true
                textView.textContainer?.widthTracksTextView = true
                scroll.documentView = textView
                alert.accessoryView = scroll
                if alert.runModal() == .alertSecondButtonReturn { self.openLogs() }
            }
        }
    }

    @objc private func openLogs() { NSWorkspace.shared.open(runtime.paths.logsURL) }

    @objc private func showProfiles() {
        guard !busy && window?.attachedSheet == nil else { return }
        if profileManager == nil {
            profileManager = DCProfileManagerController(runtime: runtime, worker: worker,
                onBusyChanged: { [weak self] value in
                    self?.profileBusy = value
                    self?.updateActionAvailability()
                }, onOpenBrowser: { [weak self] in
                    guard let self = self else { return }
                    self.window.makeKeyAndOrderFront(nil)
                    self.launchBrowser()
                }, onClose: { [weak self] in
                    guard let self = self else { return }
                    if self.manageProfilesAtLaunch && !self.window.isVisible && !self.profileBusy {
                        NSApp.terminate(nil)
                    }
                })
        }
        profileManager?.show()
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "DeChrome \(dcVersion())"
        alert.informativeText = "A minimal Chrome window with a native command palette.\n\nDeChrome prepares a separate local browser copy and profile."
        alert.runModal()
    }
}

private final class DCProfileManagerController: NSObject, NSWindowDelegate {
    private let runtime: DeChromeRuntime
    private let worker: DispatchQueue
    private let onBusyChanged: (Bool) -> Void
    private let onOpenBrowser: () -> Void
    private let onClose: () -> Void
    private var window: NSWindow!
    private var sourceField: NSTextField!
    private var profilePopup: NSPopUpButton!
    private var snapshotLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var progress: NSProgressIndicator!
    private var chooseButton: NSButton!
    private var listButton: NSButton!
    private var importButton: NSButton!
    private var updateButton: NSButton!
    private var openButton: NSButton!
    private var doneButton: NSButton!
    private var sourceRoot: URL
    private var profiles: [DCChromeProfile] = []
    private var imported: DCProfileImportState?
    private var busy = false
    private var generation = 0
    var isVisible: Bool { window?.isVisible == true }

    init(runtime: DeChromeRuntime, worker: DispatchQueue,
         onBusyChanged: @escaping (Bool) -> Void,
         onOpenBrowser: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.runtime = runtime
        self.worker = worker
        self.onBusyChanged = onBusyChanged
        self.onOpenBrowser = onOpenBrowser
        self.onClose = onClose
        let state = runtime.importedProfile()
        self.imported = state
        self.sourceRoot = state.map { URL(fileURLWithPath: $0.sourceRoot, isDirectory: true) } ??
            DCProfileImporter.defaultSourceRoot(environment: ProcessInfo.processInfo.environment)
        super.init()
        buildWindow()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !busy && window.attachedSheet == nil { loadProfiles() }
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 630),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "DeChrome — Profiles and sync"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        guard let content = window.contentView else { return }
        let title = NSTextField(labelWithString: "Profiles and sync")
        title.font = .systemFont(ofSize: 25, weight: .semibold)
        title.frame = NSRect(x: 20, y: 570, width: 660, height: 34)
        content.addSubview(title)
        let direction = NSTextField(wrappingLabelWithString:
            "Copy regular Chrome → DeChrome. After importing, both browsers can run independently with their own profile data.")
        direction.textColor = .secondaryLabelColor
        direction.frame = NSRect(x: 20, y: 514, width: 660, height: 44)
        content.addSubview(direction)
        let sourceLabel = NSTextField(labelWithString: "Chrome data folder")
        sourceLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        sourceLabel.frame = NSRect(x: 20, y: 484, width: 660, height: 18)
        content.addSubview(sourceLabel)
        sourceField = NSTextField(string: sourceRoot.path)
        sourceField.isEditable = false
        sourceField.isSelectable = true
        sourceField.lineBreakMode = .byTruncatingMiddle
        sourceField.setAccessibilityLabel("Chrome data folder")
        sourceField.frame = NSRect(x: 20, y: 452, width: 536, height: 28)
        content.addSubview(sourceField)
        chooseButton = button("Choose…", #selector(chooseSource), frame: NSRect(x: 566, y: 452, width: 114, height: 28))
        content.addSubview(chooseButton)
        let profileLabel = NSTextField(labelWithString: "Profile to copy")
        profileLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        profileLabel.frame = NSRect(x: 20, y: 420, width: 660, height: 18)
        content.addSubview(profileLabel)
        profilePopup = NSPopUpButton(frame: NSRect(x: 20, y: 388, width: 536, height: 28), pullsDown: false)
        profilePopup.setAccessibilityLabel("Chrome profile to copy")
        content.addSubview(profilePopup)
        listButton = button("Refresh list", #selector(reloadProfiles), frame: NSRect(x: 566, y: 388, width: 114, height: 28))
        content.addSubview(listButton)
        snapshotLabel = NSTextField(wrappingLabelWithString: "")
        snapshotLabel.font = .systemFont(ofSize: 12)
        snapshotLabel.frame = NSRect(x: 20, y: 308, width: 660, height: 65)
        snapshotLabel.setAccessibilityLabel("Imported profile")
        content.addSubview(snapshotLabel)
        let caution = NSTextField(wrappingLabelWithString:
            "Quit regular Chrome and DeChrome before importing or updating. An update replaces the DeChrome copy; its previous copy is kept for recovery.\n\nExtensions and settings are copied. Saved sign-ins and device-bound work features may need reauthentication or may be unavailable.")
        caution.font = .systemFont(ofSize: 12)
        caution.textColor = .secondaryLabelColor
        caution.frame = NSRect(x: 20, y: 206, width: 660, height: 88)
        content.addSubview(caution)
        progress = NSProgressIndicator(frame: NSRect(x: 20, y: 170, width: 18, height: 18))
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        content.addSubview(progress)
        statusLabel = NSTextField(wrappingLabelWithString: "Select a Chrome profile to copy.")
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 48, y: 126, width: 632, height: 62)
        statusLabel.setAccessibilityLabel("Profile copy status")
        content.addSubview(statusLabel)
        importButton = button("Import selected profile…", #selector(importSelected), frame: NSRect(x: 20, y: 70, width: 190, height: 32))
        content.addSubview(importButton)
        updateButton = button("Update from Chrome…", #selector(updateImported), frame: NSRect(x: 220, y: 70, width: 210, height: 32))
        content.addSubview(updateButton)
        doneButton = button("Done", #selector(closeWindow), frame: NSRect(x: 20, y: 20, width: 100, height: 32))
        content.addSubview(doneButton)
        openButton = button("Open Browser", #selector(openBrowser), frame: NSRect(x: 486, y: 20, width: 194, height: 32))
        content.addSubview(openButton)
        updateSnapshotLabel()
        updateControls()
    }

    private func button(_ title: String, _ action: Selector, frame: NSRect) -> NSButton {
        let control = NSButton(title: title, target: self, action: action)
        control.bezelStyle = .rounded
        control.frame = frame
        return control
    }

    private func updateSnapshotLabel() {
        guard let state = imported else {
            snapshotLabel.stringValue = "No Chrome profile has been imported.\nImporting replaces the current DeChrome profile copy and saves its previous copy for recovery."
            return
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        snapshotLabel.stringValue = "Imported profile: \(state.profileName)\nLast update: \(formatter.string(from: state.importedAt))\nSource: \(state.sourceRoot)"
        updateButton?.toolTip = "Replace the DeChrome copy with a fresh copy of \(state.profileName) from its saved Chrome source."
    }

    private func updateControls() {
        sourceField.isEnabled = !busy
        chooseButton.isEnabled = !busy
        listButton.isEnabled = !busy
        profilePopup.isEnabled = !busy && !profiles.isEmpty
        importButton.isEnabled = !busy && !profiles.isEmpty
        updateButton.isEnabled = !busy && imported != nil
        openButton.isEnabled = !busy
        doneButton.isEnabled = !busy
        window.standardWindowButton(.closeButton)?.isEnabled = !busy
    }

    private func setBusy(_ value: Bool, message: String) {
        busy = value
        onBusyChanged(value)
        statusLabel.stringValue = message
        statusLabel.textColor = .secondaryLabelColor
        updateControls()
        if value { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
    }

    private func loadProfiles() {
        guard !busy else { return }
        generation += 1
        let request = generation
        let root = sourceRoot
        let previousDirectory = profilePopup.selectedItem?.representedObject as? String ?? imported?.sourceDirectory
        setBusy(true, message: "Finding Chrome profiles…")
        worker.async {
            do {
                let found = try self.runtime.availableChromeProfiles(sourceRoot: root)
                let state = self.runtime.importedProfile()
                DispatchQueue.main.async {
                    guard request == self.generation else { return }
                    self.profiles = found
                    self.imported = state
                    self.profilePopup.removeAllItems()
                    let displayNames = found.map { profile -> String in
                        let account = profile.userName.flatMap { $0.isEmpty ? nil : $0 }.map { " — \($0)" } ?? ""
                        return "\(profile.name)\(account)"
                    }
                    for (index, profile) in found.enumerated() {
                        let label = displayNames[index]
                        let title = displayNames.filter { $0 == label }.count > 1 ?
                            "\(label) (\(profile.directory))" : label
                        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                        item.representedObject = profile.directory
                        item.toolTip = profile.directory
                        self.profilePopup.menu?.addItem(item)
                    }
                    if found.isEmpty { self.profilePopup.addItem(withTitle: "No profiles found") }
                    if let wanted = previousDirectory, let index = found.firstIndex(where: { $0.directory == wanted }) {
                        self.profilePopup.selectItem(at: index)
                    }
                    self.updateSnapshotLabel()
                    self.setBusy(false, message: found.isEmpty ?
                        "No Chrome profiles were found. Choose the Chrome data folder if it is stored elsewhere." :
                        "Select a profile to import, or update the previously imported profile. Quit both browsers before copying.")
                }
            } catch {
                DispatchQueue.main.async {
                    guard request == self.generation else { return }
                    self.profiles = []
                    self.profilePopup.removeAllItems()
                    self.profilePopup.addItem(withTitle: "Profiles unavailable")
                    self.setBusy(false, message: error.localizedDescription)
                    self.statusLabel.textColor = .systemRed
                }
            }
        }
    }

    @objc private func chooseSource() {
        guard !busy && window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Chrome data folder"
        panel.message = "Choose the folder containing Chrome's profiles. The default folder is normally Google/Chrome in your Application Support folder."
        panel.prompt = "Use Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = sourceRoot
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let selected = panel.url else { return }
            self.sourceRoot = selected
            self.sourceField.stringValue = selected.path
            self.loadProfiles()
        }
    }

    @objc private func reloadProfiles() { loadProfiles() }

    @objc private func importSelected() {
        guard !busy && window.attachedSheet == nil,
              profiles.indices.contains(profilePopup.indexOfSelectedItem) else { return }
        let profile = profiles[profilePopup.indexOfSelectedItem]
        confirmCopy(profileName: profile.name, source: sourceRoot, updating: false) {
            let root = self.sourceRoot
            self.performCopy(message: "Copying \(profile.name) into DeChrome…") {
                try self.runtime.importChromeProfile(directory: profile.directory, sourceRoot: root)
            }
        }
    }

    @objc private func updateImported() {
        guard !busy && window.attachedSheet == nil, let state = imported else { return }
        confirmCopy(profileName: state.profileName,
                    source: URL(fileURLWithPath: state.sourceRoot, isDirectory: true), updating: true) {
            self.performCopy(message: "Updating DeChrome from \(state.profileName)…") {
                try self.runtime.refreshChromeProfile(expectedSnapshotID: state.snapshotID)
            }
        }
    }

    private func confirmCopy(profileName: String, source: URL, updating: Bool, confirmed: @escaping () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = updating ? "Update DeChrome from “\(profileName)”?" : "Import “\(profileName)” into DeChrome?"
        alert.informativeText = "Source: \(source.path)\n\nQuit regular Chrome and DeChrome first. This replaces the DeChrome profile copy and keeps its previous copy for recovery. Updates go from Chrome to DeChrome only.\n\nSaved sign-ins and device-bound work features may require signing in again or may be unavailable."
        alert.addButton(withTitle: updating ? "Update Profile" : "Import Profile")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { confirmed() }
        }
    }

    private func performCopy(message: String, operation: @escaping () throws -> DCProfileImportState) {
        guard !busy else { return }
        generation += 1
        let request = generation
        setBusy(true, message: message)
        worker.async {
            do {
                let state = try operation()
                DispatchQueue.main.async {
                    guard request == self.generation else { return }
                    self.imported = state
                    self.updateSnapshotLabel()
                    self.setBusy(false, message: "Profile copy complete. Open Browser when ready. Regular Chrome's source profile is unchanged.")
                }
            } catch {
                DispatchQueue.main.async {
                    guard request == self.generation else { return }
                    self.setBusy(false, message: error.localizedDescription)
                    self.statusLabel.textColor = .systemRed
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "The profile could not be copied"
                    alert.informativeText = error.localizedDescription
                    alert.addButton(withTitle: "OK")
                    alert.beginSheetModal(for: self.window)
                }
            }
        }
    }

    @objc private func openBrowser() {
        guard !busy && window.attachedSheet == nil else { return }
        window.orderOut(nil)
        onOpenBrowser()
    }

    @objc private func closeWindow() { window.performClose(nil) }

    func windowShouldClose(_ sender: NSWindow) -> Bool { !busy }

    func windowWillClose(_ notification: Notification) {
        generation += 1
        onClose()
    }
}

@main
private struct DeChromeEntry {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }
        let isApp = arguments.isEmpty && Bundle.main.bundleURL.pathExtension == "app"
        if isApp || arguments == ["app"] || arguments == ["profiles-ui"] {
            let app = NSApplication.shared
            let delegate = DCAppDelegate(manageProfilesAtLaunch: arguments == ["profiles-ui"])
            app.delegate = delegate
            app.setActivationPolicy(.regular)
            withExtendedLifetime(delegate) { app.run() }
            return
        }
        do { exit(try dcRunCLI(arguments)) }
        catch {
            FileHandle.standardError.write(Data("DeChrome: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
