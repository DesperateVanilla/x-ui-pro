import os
import pathlib
import subprocess
import tempfile
import unittest

from test_installer import find_bash


ROOT = pathlib.Path(__file__).resolve().parent.parent


class TestInstallerRecoveryEntry(unittest.TestCase):
    def run_entry(self, name: str, existing: bool, helper_status: int = 0) -> tuple[subprocess.CompletedProcess[str], str]:
        source = (ROOT / name).read_text(encoding="utf-8")
        start = source.index("# Protocol recovery entry point.\n")
        end = source.index("# End protocol recovery entry point.\n", start)
        section = source[start:end]
        with tempfile.TemporaryDirectory(prefix="installer recovery ") as temp:
            folder = pathlib.Path(temp)
            db = folder / "x-ui.db"
            if existing:
                db.touch()
            calls = folder / "calls"
            helper = folder / "add_protocol.sh"
            helper.write_text(
                '#!/bin/bash\nprintf "%s\\n" "$*" > "$CALL_FILE"\nexit "$HELPER_STATUS"\n',
                encoding="utf-8", newline="\n",
            )
            runner = folder / "installer.sh"
            runner.write_text(
                '#!/bin/bash\nXUIDB="$TEST_DB"\nmsg_inf() { :; }\nmsg_err() { echo "$1" >&2; }\n'
                + section + '\necho FRESH_INSTALL\n', encoding="utf-8", newline="\n",
            )
            env = dict(os.environ, CALL_FILE=calls.as_posix(), TEST_DB=db.as_posix(), HELPER_STATUS=str(helper_status))
            result = subprocess.run([find_bash(), runner.as_posix()], capture_output=True, text=True, env=env, timeout=15)
            return result, calls.read_text().strip() if calls.exists() else ""

    def test_existing_panel_only_recovers_missing_protocols(self) -> None:
        for name in ("x-ui-pro.sh", "x-ui-latest.sh"):
            with self.subTest(script=name):
                result, call = self.run_entry(name, existing=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(call, "all")
                self.assertNotIn("FRESH_INSTALL", result.stdout)

    def test_recovery_failure_does_not_continue_into_fresh_install(self) -> None:
        for name in ("x-ui-pro.sh", "x-ui-latest.sh"):
            with self.subTest(script=name):
                result, call = self.run_entry(name, existing=True, helper_status=7)
                self.assertEqual(result.returncode, 7)
                self.assertEqual(call, "all")
                self.assertNotIn("FRESH_INSTALL", result.stdout)

    def test_fresh_panel_continues_to_installation(self) -> None:
        for name in ("x-ui-pro.sh", "x-ui-latest.sh"):
            with self.subTest(script=name):
                result, call = self.run_entry(name, existing=False)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(call, "")
                self.assertIn("FRESH_INSTALL", result.stdout)


if __name__ == "__main__":
    unittest.main()
