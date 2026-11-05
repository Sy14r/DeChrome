#!/usr/bin/env python3
"""The release allowlist must run before signing or notarization can occur."""
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("package_release", ROOT / "scripts/package_release.py")
package_release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(package_release)


class ReleasePrivacyTests(unittest.TestCase):
    def test_extra_file_is_rejected_before_signing_or_notarization(self):
        with tempfile.TemporaryDirectory(prefix="DeChromePackagePrivacy-") as temporary:
            root = Path(temporary)
            app = root / "build/DeChrome.app"
            resources = app / "Contents/Resources"
            resources.mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleShortVersionString": "0.2.0", "LSMinimumSystemVersion": "13.0",
            }))
            (resources / "build-info.json").write_text(json.dumps({"version": "0.2.0"}))
            # Synthetic private data: never a real Chrome profile or credential.
            (resources / "accidental-profile.json").write_text('{"syntheticPrivateData": true}')
            operations = []

            def record_run(*arguments):
                operations.append(tuple(str(value) for value in arguments))
                if arguments[0] != "/usr/bin/ditto":
                    self.fail("Signing/stapling ran before rejecting the private file")
                shutil.copytree(arguments[1], arguments[2])

            def reject_external_process(*_args, **_kwargs):
                self.fail("Notarization ran before rejecting the private file")

            argv = ["package_release.py", "--skip-build", "--identity", "Synthetic Developer ID",
                    "--notary-profile", "Synthetic Notary Profile"]
            with patch.object(package_release, "ROOT", root), \
                 patch.object(package_release, "run", side_effect=record_run), \
                 patch.object(package_release.subprocess, "run", side_effect=reject_external_process), \
                 patch("sys.argv", argv):
                with self.assertRaisesRegex(SystemExit, "accidental-profile.json"):
                    package_release.main()

            self.assertEqual(len(operations), 1)
            self.assertEqual(operations[0][0], "/usr/bin/ditto")
            self.assertFalse(any((root / "dist").glob("*.zip")))
            self.assertEqual(json.loads((resources / "build-info.json").read_text()), {"version": "0.2.0"})


if __name__ == "__main__":
    unittest.main()
