#!/usr/bin/env python3
"""Package only DeChrome components; never include a browser or user profile."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
ALLOWED_FILES = {
    "Contents/Info.plist", "Contents/PkgInfo", "Contents/MacOS/DeChrome",
    "Contents/Resources/DeChrome.dylib", "Contents/Resources/Start.html",
    "Contents/Resources/AppIcon.icns", "Contents/Resources/build-info.json",
    "Contents/_CodeSignature/CodeResources", "Contents/CodeResources",
}


def run(*arguments):
    return subprocess.run([str(value) for value in arguments], check=True, text=True)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validated_files(app):
    """Reject unexpected data before signing or sending this bundle anywhere."""
    files = {}
    for path in app.rglob("*"):
        if path.is_symlink():
            raise SystemExit(f"Unexpected symlink in app: {path.relative_to(app)}")
        if not path.is_file():
            continue
        relative = str(path.relative_to(app))
        if relative not in ALLOWED_FILES:
            raise SystemExit(f"Refusing to package unexpected file: {relative}")
        files[relative] = digest(path)
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--identity", help="Developer ID Application signing identity")
    parser.add_argument("--notary-profile", help="existing notarytool keychain profile; submits to Apple")
    args = parser.parse_args()
    if args.notary_profile and not args.identity:
        parser.error("--notary-profile requires --identity")
    if not args.skip_build:
        run(ROOT / "scripts/build.sh")
    built_app = ROOT / "build/DeChrome.app"
    info = plistlib.loads((built_app / "Contents/Info.plist").read_bytes())
    version = info["CFBundleShortVersionString"]
    name = f"DeChrome-{version}-macos-arm64"
    destination = ROOT / "dist"
    destination.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".package-", dir=destination) as temporary:
        release = Path(temporary) / name
        release.mkdir()
        app = release / "DeChrome.app"
        run("/usr/bin/ditto", built_app, app)
        # In particular, --skip-build must not upload an accidentally modified
        # development bundle to Apple before its contents have been checked.
        validated_files(app)
        mode = "ad-hoc development"
        notarized = False
        if args.identity:
            mode = "Developer ID"
            build_info_path = app / "Contents/Resources/build-info.json"
            build_info = json.loads(build_info_path.read_text())
            build_info["signing"] = mode
            build_info_path.write_text(json.dumps(build_info, indent=2) + "\n")
            for target in [app / "Contents/Resources/DeChrome.dylib", app]:
                run("/usr/bin/codesign", "--force", "--sign", args.identity,
                    "--options", "runtime", "--timestamp", target)
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", app)
        if args.notary_profile:
            submission = Path(temporary) / "notarization.zip"
            run("/usr/bin/ditto", "-c", "-k", "--keepParent", app, submission)
            result = subprocess.run([
                "/usr/bin/xcrun", "notarytool", "submit", str(submission),
                "--keychain-profile", args.notary_profile, "--wait", "--output-format", "json",
            ], capture_output=True, text=True, check=True)
            report = json.loads(result.stdout)
            (destination / f"{name}-notarization.json").write_text(json.dumps(report, indent=2) + "\n")
            if report.get("status") != "Accepted":
                raise SystemExit(f"Apple did not accept this submission; see dist/{name}-notarization.json")
            run("/usr/bin/xcrun", "stapler", "staple", app)
            run("/usr/bin/xcrun", "stapler", "validate", app)
            notarized = True
        # Revalidate after signing/stapling and hash the actual release bytes.
        files = validated_files(app)
        provenance = json.loads((app / "Contents/Resources/build-info.json").read_text())
        manifest = {
            "name": "DeChrome", "version": version, "architecture": "arm64",
            "minimumMacOS": info["LSMinimumSystemVersion"], "signing": mode,
            "notarized": notarized, "includesChrome": False, "includesUserData": False,
            "runtimeVerifiedMacOS": ["26.6.2"],
            "experimentalTabs": bool(info.get("DeChromeExperimentalTabs", False)),
            "sourceCommit": provenance.get("sourceCommit"),
            "sourceDirty": provenance.get("sourceDirty"),
            "macOS27": "requires on-device validation", "files": files,
        }
        (release / "Release.json").write_text(json.dumps(manifest, indent=2) + "\n")
        signing_note = ("This release is Developer ID signed and notarized." if notarized else
                        "This is a development release. It has not been notarized by Apple.")
        tabs_note = ("This is the experimental tabs preview. Command-T creates a tab; Command-W closes it.\n"
                     "Command-K switches tabs or navigates; Control-Tab and Command-1 through9 also switch.\n"
                     "Use --single-page with the CLI, or uncheck Enable tabs in the recovery window, for the 0.1 mode.\n\n"
                     if manifest["experimentalTabs"] else "")
        (release / "Install.txt").write_text(
            "DeChrome for Apple Silicon\n\n"
            "Drag DeChrome.app to your Applications folder, then open it.\n"
            "Google Chrome must already be installed. First launch prepares a private copy.\n"
            "Press Command-K to navigate or run commands; Command-L for the current URL.\n\n"
            + tabs_note +
            "Application data: ~/Library/Application Support/DeChrome\n"
            "Logs: ~/Library/Logs/DeChrome\n"
            "The installed Chrome app and ordinary Chrome profile remain separate.\n"
            "The private copy refreshes from installed Chrome when DeChrome starts while closed.\n\n"
            + signing_note + "\n"
            "The generated Chrome copy is signed locally, separately from this launcher.\n"
            "A managed work Mac may restrict modified browsers or Chrome debugging.\n"
            "This installer does not change Gatekeeper, quarantine, SIP, or company policies.\n"
            "macOS 27 has not yet been runtime-tested. Startup validates frame and palette readiness.\n\n"
            "Diagnostics from Terminal:\n"
            "  /Applications/DeChrome.app/Contents/MacOS/DeChrome doctor\n"
            "  /Applications/DeChrome.app/Contents/MacOS/DeChrome refresh\n"
            "Quit the DeChrome browser before refreshing. Profile data is preserved.\n"
        )
        archive = destination / f"{name}.zip"
        archive.unlink(missing_ok=True)
        run("/usr/bin/ditto", "-c", "-k", "--keepParent", release, archive)
        with zipfile.ZipFile(archive) as packaged:
            for item in packaged.namelist():
                if "Google Chrome.app" in item or any(part in {"profile", "Profile", "build", "logs"} for part in Path(item).parts):
                    archive.unlink()
                    raise SystemExit(f"Unexpected private data path in archive: {item}")
        checksum = digest(archive)
        (destination / f"{archive.name}.sha256").write_text(f"{checksum}  {archive.name}\n")
        (destination / f"{name}-Release.json").write_text(json.dumps(manifest, indent=2) + "\n")
        print(f"Packaged {archive}")
        print(f"SHA-256 {checksum}")
        print(f"Signing: {mode}; notarized: {notarized}")


if __name__ == "__main__":
    main()
