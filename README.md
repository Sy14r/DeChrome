# DeChrome

Actual Google Chrome with just page content: no visible title bar, tab bar, address bar, traffic-light buttons, or window shadow. Rounded macOS corners remain. AeroSpace can tile, focus, and resize the window normally.

DeChrome is a small native Apple Silicon launcher. It uses Chrome already installed on the destination Mac and prepares a private, locally signed copy. The installed Chrome application and ordinary Chrome profile stay separate.

**0.2.0 is an experimental tabs preview.** It uses real Chrome tabs with their bar hidden. Tabs are enabled by default in this preview. The **0.1.0 single-page release is retained** as a stable fallback.

## Install on another Mac

Download the Apple Silicon ZIP from [GitHub Releases](https://github.com/Sy14r/DeChrome/releases), rather than copying this project directory. Locally packaged ZIPs are also written to `dist/`.

1. Extract the ZIP and drag **DeChrome.app** to Applications or your user Applications folder.
2. Ensure Google Chrome is installed normally.
3. Open DeChrome. The first launch prepares its private browser and opens the start page.
4. Press **⌘K** to navigate or run a browser command.

When upgrading, quit the DeChrome browser before opening the new app. The next launch uses the new version and preserves its profile.

The app bundles its native launcher and shim. Python and a compiler are not part of the destination launch process. It uses standard macOS copy and code-signing tools to prepare Chrome locally.

The **0.2.0 preview and retained 0.1.0 release are Developer ID signed and Apple notarized**, with their tickets stapled. Check each ZIP's release manifest for its version, signing, and notarization state. Source builds are locally signed development builds until passed through the release-signing workflow. A managed work Mac may still reject the generated modified browser or restrict Chrome debugging. DeChrome reports those failures and does not change Gatekeeper, quarantine, SIP, or company policies.

This build targets **Apple Silicon / macOS 13 or newer**. Runtime behavior has been verified on **macOS 26.6.2 / Chrome 156.0.8078.80**. The minimum deployment target does not establish compatibility with every intervening or future macOS release. **macOS 27 needs an on-device test.**

## Use

- **⌘K:** find open tabs, navigate, search Google, or run a browser command.
- **⌘L:** palette with the current address selected.
- **↑ / ↓ / Return:** choose and execute a result.
- **Escape:** dismiss and return focus to the page.

Commands include Back, Forward, Reload, Hard Reload, Zoom In/Out, Reset Zoom, Find in Page, Copy URL, Developer Tools, and Close Window. Hostnames default to HTTPS; localhost uses HTTP. Explicit HTTP, HTTPS, file, and Chrome URLs work.

In the tabs preview:

| Shortcut | Action |
| --- | --- |
| **⌘T** | Create a tab and open the URL palette |
| **⌘W** | Close the current tab |
| **⇧⌘W** | Close the window and its tabs |
| **⌃Tab / ⌃⇧Tab** | Next / previous tab |
| **⌘1–8 / ⌘9** | Select a tab by position / select the last tab |

The palette shows tab titles, addresses, and a current-tab marker. Type part of a title or URL to find a tab, or run **Switch Tab** to show only open tabs. New Tab, Close Tab, Next Tab, and Previous Tab are also available as commands. No permanent tab strip is displayed.

To return to the single-page implementation, stop DeChrome and launch with `--single-page`. If startup fails, the launcher's recovery window also offers an **Enable tabs (experimental)** checkbox; clearing it selects the single-page path and saves that GUI preference.

Reopening DeChrome focuses its existing managed Chrome process. To navigate an already open window, use its palette. An explicit address delivered to the launcher while a browser is open is shown with navigation guidance; it does not silently replace the current page.

## Storage and updates

All generated data lives outside the application:

| Location | Contents |
| --- | --- |
| `~/Library/Application Support/DeChrome/Browser/` | Current private Chrome copy and preparation metadata |
| `~/Library/Application Support/DeChrome/Browser.previous/` | Previous prepared copy, when available |
| `~/Library/Application Support/DeChrome/Profile/` | DeChrome cookies, logins, preferences, and browsing history |
| `~/Library/Logs/DeChrome/` | Browser and native diagnostic logs |

The ordinary Chrome installation remains the source of browser updates. When installed Chrome advances, the next DeChrome launch while stopped prepares a fresh private copy. Preparation happens in a separate staging directory; signing or copy failures preserve the previous complete browser. The profile is preserved across refreshes.

Chrome's updater registration keys are removed from the private copy so it does not register over the installed browser. DeChrome does not download its own Chrome build or modify the original app.

Rollback restores a previous prepared browser only when compatible with the profile's recorded browser version. It refuses a browser downgrade after a newer Chrome has opened the profile. Interrupted swaps are recovered on the next preparation. Browser rollback is not a profile backup system.

## Diagnostics and CLI

The app executable also provides a native CLI:

```sh
"/Applications/DeChrome.app/Contents/MacOS/DeChrome" doctor
"/Applications/DeChrome.app/Contents/MacOS/DeChrome" launch https://example.com
"/Applications/DeChrome.app/Contents/MacOS/DeChrome" launch --single-page https://example.com
"/Applications/DeChrome.app/Contents/MacOS/DeChrome" status --json
"/Applications/DeChrome.app/Contents/MacOS/DeChrome" stop
"/Applications/DeChrome.app/Contents/MacOS/DeChrome" refresh
"/Applications/DeChrome.app/Contents/MacOS/DeChrome" rollback
```

Use the corresponding path if installed in your user Applications folder. `doctor` checks architecture, OS, Chrome, resources, available policy settings, profile version records, and managed process state. It cannot establish workplace approval. Refresh and rollback require the browser to be stopped.

On startup, DeChrome requires a fresh report from its injected shim confirming a normal accessible window with the page filling its physical frame. It also verifies a working Chrome DevTools Protocol command, not just an open port. Cold launches allow up to 90 seconds for macOS assessment of the locally signed Chrome copy. If readiness fails, the new child is stopped and an actionable error points to logs.

The palette's debugging interface listens at a random **127.0.0.1** port only. It can control this separate profile. No permissive debugging-origin flag is used. Keep the ordinary browser profile separate.

## Build from source

Building requires Xcode or Command Line Tools with Swift and clang. Python 3 is used only by the developer release-packaging script.

```sh
./scripts/build.sh
./dechrome doctor
./dechrome launch
./dechrome stop
./dechrome refresh
```

The source wrapper rebuilds `build/DeChrome.app` when its inputs change. `./dechrome build` explicitly rebuilds it. The native launcher and dylib are compiled for `arm64-apple-macos13.0`; no Python runtime is embedded or invoked by the app.

The prototype profile formerly stored at `build/profile/` can be copied into the new Profile directory while both browsers are stopped and the destination is empty. Preserve the old copy as a backup. Do not copy a live Chrome profile or overwrite an existing destination profile.

Developer overrides support isolated testing: `DECHROME_DATA_DIR`, `DECHROME_LOG_DIR`, `DECHROME_CHROME_PATH`, and `DECHROME_RESOURCES_DIR`. Use dedicated directories. Release launches discard development-only crop and self-test settings.

## Make a release

```sh
./scripts/release.sh
```

This builds a clean development app, verifies its code signature, and writes an Apple Silicon ZIP, release manifest, and SHA-256 checksum to `dist/`. The package allowlist includes only the launcher, shim, start page, app icon, signatures, and install/release notes. It excludes Chrome, profiles, cookies, process records, build caches, and logs.

For an Apple Developer ID release, provide an existing signing identity and notarytool keychain profile:

```sh
./scripts/release.sh \
  --identity 'Developer ID Application: Your Name (TEAMID)' \
  --notary-profile 'your-notarytool-profile'
```

That command signs the nested dylib and app, submits the app to Apple's notary service, requires an Accepted result, staples the ticket, and recreates the final ZIP with a checksum. Credentials are not stored in this repository. It is the only packaging mode that submits software externally.

GitHub releases attach the ZIP, SHA-256 checksum, and release manifest to a version tag. The app's build information and release manifest record the source commit and whether the checkout had uncommitted changes at build time. Build from a clean commit before tagging and publishing a release. Experimental previews are marked as prereleases.

Signing/notarizing the launcher does not notarize its generated Chrome copy. That copy is ad-hoc signed locally with DYLD and library-validation exceptions; the renderer sandbox remains enabled. Work-laptop controls can still reject it.

## Verification

```sh
./scripts/test.sh
python3 tests/test_package_privacy.py
```

The native integration suite uses temporary headless fake Chrome applications, not the real browser. It exercises actual copying/signing, idempotence, refresh/profile preservation, staged failure recovery, interrupted swaps, operation locking, process identity, missing-state profile protection, stop, and downgrade/corrupt-version refusal.

The 0.1.0 release passed 13 lifecycle tests and a clean first install in about 25 seconds, including macOS assessment, frame validation, and a real palette/CDP command. Its live checks on macOS 26.6.2 include frame removal, page focus, native resize/restore, AeroSpace tiling/focus/resize, palette navigation in the same window, history, reload, zoom, Find, Copy URL, and Escape restoring page focus.

The 0.2.0 preview passed 14 lifecycle tests and the packaging privacy regression. Live checks used isolated synthetic pages with identical titles: real tab creation, independent drafts and JavaScript state across switches, title/URL tab search, tab shortcuts, links opening tabs, active-tab history, individual tab close, window close preserving another window's tabs, and process exit after the last tab closes. AeroSpace tiling changed the visible viewport from 1699 to 500 pixels wide and back without revealing Chrome's header. Rapid navigation followed immediately by a new tab preserved each tab's intended URL.

The final notarized 0.2.0 ZIP passed signature, stapled-ticket, Gatekeeper, manifest, and checksum checks. A fresh default-mode install from a path containing spaces reached window and command readiness in about 44 seconds. Its test browser was stopped and temporary profiles were removed.

Internal native view classes and experimental Chrome tab metadata can change with Chrome or macOS. A brief browser-header flash may occur before configuration. Two-window tab scoping was checked; more complex multi-monitor arrangements, installed PWAs, docked DevTools layouts, and fullscreen transitions remain unverified. Ambiguous page targets produce an error instead of guessing. A tab whose metadata is still starting asks you to retry navigation. A separate borders utility can still draw its configured outline. macOS 27 remains untested.

## Remove

Stop DeChrome, then remove its app. Its data and logs remain in the locations above so an app update or reinstall preserves the profile. Remove those directories separately only if you intend to erase DeChrome's browsing data.
