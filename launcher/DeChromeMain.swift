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
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0"
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
  dechrome version
  dechrome help

Launch automatically refreshes the private browser when installed Chrome changes.
Chrome profiles and logs are stored separately from this application.
This preview enables hidden tabs by default. --single-page uses the 0.1 app-window mode.
"""

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
    private var tabsCheckbox: NSButton!
    private var busy = false
    private var pendingURL: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        // Finder can deliver an initial Open URL event during launch. Give it
        // one main-loop turn to populate the address before starting setup.
        DispatchQueue.main.async { self.launchBrowser() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !busy }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !busy && window != nil && window.attachedSheet == nil { launchBrowser() }
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
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setBusy(_ value: Bool, message: String) {
        busy = value
        address.isEnabled = !value
        openButton.isEnabled = !value
        refreshButton.isEnabled = !value
        diagnosticsButton.isEnabled = !value
        tabsCheckbox.isEnabled = !value
        statusLabel.stringValue = message
        statusLabel.textColor = .secondaryLabelColor
        if value { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
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
        guard !busy && window.attachedSheet == nil else { return }
        let typed = address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = typed.isEmpty ? pendingURL : typed
        let useTabs = tabsCheckbox.state == .on
        pendingURL = nil
        setBusy(true, message: "Opening your browser… First launch can take up to 45 seconds.")
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
        guard !busy && window.attachedSheet == nil else { return }
        setBusy(true, message: "Refreshing the private Chrome copy…")
        worker.async {
            do {
                let result = try self.runtime.prepare(force: true)
                DispatchQueue.main.async { self.setBusy(false, message: "Chrome \(result.version) is ready. Open Browser to continue.") }
            } catch { DispatchQueue.main.async { self.showError(error) } }
        }
    }

    @objc private func showDiagnostics() {
        guard !busy && window.attachedSheet == nil else { return }
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

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "DeChrome \(dcVersion())"
        alert.informativeText = "A minimal Chrome window with a native command palette.\n\nDeChrome prepares a separate local browser copy and profile."
        alert.runModal()
    }
}

@main
private struct DeChromeEntry {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }
        let isApp = arguments.isEmpty && Bundle.main.bundleURL.pathExtension == "app"
        if isApp || arguments == ["app"] {
            let app = NSApplication.shared
            let delegate = DCAppDelegate()
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
