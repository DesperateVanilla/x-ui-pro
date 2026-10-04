import base64
import json
import os
import pathlib
import re
import shlex
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from typing import Any, NamedTuple
import unittest

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT_PATH = REPO_ROOT / "x-ui-pro.sh"


def find_bash() -> str:
    candidate: str | None = None
    if sys.platform == "win32":
        default_win_bash = r"C:\Program Files\Git\bin\bash.exe"
        if os.path.isfile(default_win_bash):
            candidate = default_win_bash
        else:
            candidate = shutil.which("bash")
    else:
        candidate = shutil.which("bash")

    if not candidate or not os.path.isfile(candidate):
        raise unittest.SkipTest("Bash executable not found on this system.")
    return candidate


def extract_awg_block(script_path: pathlib.Path) -> str:
    content = script_path.read_text(encoding="utf-8")
    pattern = (
        r"(awg_output=\$\(/usr/local/x-ui/bin/xray-linux-amd64 x25519\).*?)"
        r"(?=\n\s*(?:ip_info=|node_name=|echo -e \".*?Generating AmneziaWG))"
    )
    match = re.search(pattern, content, re.DOTALL)
    if not match:
        raise ValueError(f"Could not extract AWG block from {script_path}")
    return match.group(1)


def run_extracted_awg_block(server_output: str, client_output: str) -> dict[str, str]:
    bash_path = find_bash()
    extracted_block = extract_awg_block(SCRIPT_PATH)

    with tempfile.TemporaryDirectory(prefix="installer keys ") as td:
        td_path = pathlib.Path(td)
        server_output_file = td_path / "server_output.txt"
        client_output_file = td_path / "client_output.txt"
        call_count_file = td_path / "call_count.txt"
        stub_path = td_path / "xray-linux-amd64"
        runner_path = td_path / "run_test.sh"

        with open(server_output_file, "w", encoding="utf-8", newline="\n") as f:
            f.write(server_output)

        with open(client_output_file, "w", encoding="utf-8", newline="\n") as f:
            f.write(client_output)

        stub_content = f"""#!/bin/sh
if [ "$1" = "x25519" ]; then
    call_file="${{CALL_FILE:-{shlex.quote(call_count_file.as_posix())}}}"
    server_file="${{SERVER_OUTPUT_FILE:-{shlex.quote(server_output_file.as_posix())}}}"
    client_file="${{CLIENT_OUTPUT_FILE:-{shlex.quote(client_output_file.as_posix())}}}"
    count=0
    if [ -f "$call_file" ]; then
        count=$(cat "$call_file")
    fi
    count=$((count + 1))
    echo "$count" > "$call_file"

    if [ $((count % 2)) -eq 1 ]; then
        cat "$server_file"
    else
        cat "$client_file"
    fi
fi
"""
        with open(stub_path, "w", encoding="utf-8", newline="\n") as f:
            f.write(stub_content)
        stub_path.chmod(0o755)

        quoted_stub = shlex.quote(stub_path.as_posix())
        modified_block = extracted_block.replace("/usr/local/x-ui/bin/xray-linux-amd64", quoted_stub)

        runner_content = f"""{modified_block}

echo "SERVER_PRIV=$server_priv"
echo "SERVER_PUB=$server_pub"
echo "CLIENT_PRIV=$client_priv"
echo "CLIENT_PUB=$client_pub"
"""
        with open(runner_path, "w", encoding="utf-8", newline="\n") as f:
            f.write(runner_content)
        runner_path.chmod(0o755)

        env = dict(os.environ)
        env["CALL_FILE"] = call_count_file.as_posix()
        env["SERVER_OUTPUT_FILE"] = server_output_file.as_posix()
        env["CLIENT_OUTPUT_FILE"] = client_output_file.as_posix()

        proc = subprocess.run(
            [bash_path, runner_path.as_posix()],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=30,
        )

        if proc.returncode != 0:
            raise RuntimeError(
                f"Bash execution failed with code {proc.returncode}:\n"
                f"STDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}"
            )

        keys: dict[str, str] = {}
        for line in proc.stdout.splitlines():
            for prefix in ("SERVER_PRIV=", "SERVER_PUB=", "CLIENT_PRIV=", "CLIENT_PUB="):
                if line.startswith(prefix):
                    var_name = prefix[:-1].lower()
                    keys[var_name] = line[len(prefix):].strip()

        return keys


class TestCaseData(NamedTuple):
    server_output: str
    client_output: str
    expected_keys: dict[str, bytes]


def _build_test_case(
    b_server_priv: bytes,
    b_server_pub: bytes,
    b_client_priv: bytes,
    b_client_pub: bytes,
    urlsafe_raw43: bool,
    server_pub_label: str,
    client_pub_label: str,
) -> TestCaseData:
    def encode_key(b: bytes) -> str:
        if urlsafe_raw43:
            return base64.urlsafe_b64encode(b).decode().rstrip("=")
        return base64.b64encode(b).decode()

    server_output = (
        f"PrivateKey: {encode_key(b_server_priv)}\n"
        f"{server_pub_label}: {encode_key(b_server_pub)}\n"
    )
    client_output = (
        f"PrivateKey: {encode_key(b_client_priv)}\n"
        f"{client_pub_label}: {encode_key(b_client_pub)}\n"
    )
    expected_keys = {
        "server_priv": b_server_priv,
        "server_pub": b_server_pub,
        "client_priv": b_client_priv,
        "client_pub": b_client_pub,
    }
    return TestCaseData(server_output, client_output, expected_keys)


TEST_SCENARIOS: dict[str, TestCaseData] = {
    "raw43_with_urlsafe_chars": _build_test_case(
        b_server_priv=b"\x01" * 30 + b"\xfb\xff",
        b_server_pub=b"\x02" * 30 + b"\xfb\xff",
        b_client_priv=b"\x03" * 30 + b"\xfb\xff",
        b_client_pub=b"\x04" * 30 + b"\xfb\xff",
        urlsafe_raw43=True,
        server_pub_label="Password (PublicKey)",
        client_pub_label="Password (PublicKey)",
    ),
    "padded44_standard_base64": _build_test_case(
        b_server_priv=bytes(range(0, 32)),
        b_server_pub=bytes(range(32, 64)),
        b_client_priv=bytes(range(64, 96)),
        b_client_pub=bytes(range(96, 128)),
        urlsafe_raw43=False,
        server_pub_label="PublicKey",
        client_pub_label="Password",
    ),
    "raw43_with_alternate_labels": _build_test_case(
        b_server_priv=b"\x10" * 30 + b"\xfb\xff",
        b_server_pub=b"\x20" * 30 + b"\xfb\xff",
        b_client_priv=b"\x30" * 30 + b"\xfb\xff",
        b_client_pub=b"\x40" * 30 + b"\xfb\xff",
        urlsafe_raw43=True,
        server_pub_label="PublicKey",
        client_pub_label="Password",
    ),
}


class TestAWGKeyGeneration(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        find_bash()

    def _assert_keys(
        self,
        keys: dict[str, str],
        expected_keys: dict[str, bytes],
    ) -> None:
        for name, expected_bytes in expected_keys.items():
            with self.subTest(key=name):
                val = keys.get(name, "")
                self.assertTrue(bool(val), f"{name} is empty: {keys}")
                self.assertEqual(len(val), 44, f"{name} length is not 44: '{val}'")
                self.assertTrue(val.endswith("="), f"{name} must end with '=': '{val}'")
                decoded = base64.b64decode(val, validate=True)
                self.assertEqual(len(decoded), 32, f"{name} decoded bytes length != 32")
                self.assertEqual(decoded, expected_bytes, f"{name} decoded bytes mismatch")

    def _run_scenario(self, scenario_name: str) -> None:
        scenario = TEST_SCENARIOS[scenario_name]
        keys = run_extracted_awg_block(scenario.server_output, scenario.client_output)
        self._assert_keys(keys, scenario.expected_keys)

    def test_raw43_with_urlsafe_chars(self) -> None:
        scenario = TEST_SCENARIOS["raw43_with_urlsafe_chars"]
        raw_key = scenario.server_output.splitlines()[0].split(": ", 1)[1]
        self.assertEqual(len(raw_key), 43)
        self.assertTrue("-" in raw_key and "_" in raw_key)
        self._run_scenario("raw43_with_urlsafe_chars")

    def test_padded44_standard_base64(self) -> None:
        scenario = TEST_SCENARIOS["padded44_standard_base64"]
        padded_key = scenario.server_output.splitlines()[0].split(": ", 1)[1]
        self.assertEqual(len(padded_key), 44)
        self._run_scenario("padded44_standard_base64")

    def test_raw43_with_alternate_labels(self) -> None:
        self._run_scenario("raw43_with_alternate_labels")


def extract_awg_inbound_insert(script_path: pathlib.Path) -> str:
    content = script_path.read_text(encoding="utf-8")
    pattern = r'(INSERT INTO "inbounds"[^;]*?\'amneziawg\'[^;]*?\);)'
    match = re.search(pattern, content, re.DOTALL)
    if not match:
        raise ValueError(f"Could not extract AWG inbound INSERT from {script_path}")
    return match.group(1)


def expand_awg_inbound_insert(
    insert_sql: str,
    variables: dict[str, str | int],
) -> str:
    bash_path = find_bash()
    var_lines: list[str] = []
    for k, v in variables.items():
        if isinstance(v, int):
            var_lines.append(f"{k}={v}")
        else:
            var_lines.append(f"{k}={shlex.quote(str(v))}")
    vars_header = "\n".join(var_lines)

    with tempfile.TemporaryDirectory(prefix="installer_awg_expand_") as td:
        script_file = pathlib.Path(td) / "expand.sh"
        runner_content = (
            "#!/bin/bash\n"
            "set -euo pipefail\n"
            f"{vars_header}\n\n"
            "/bin/cat <<__EOF_AWG_SQL_EXPAND__\n"
            f"{insert_sql}\n"
            "__EOF_AWG_SQL_EXPAND__\n"
        )
        with open(script_file, "w", encoding="utf-8", newline="\n") as f:
            f.write(runner_content)
        script_file.chmod(0o755)

        proc = subprocess.run(
            [bash_path, script_file.as_posix()],
            capture_output=True,
            text=True,
            check=False,
            timeout=30,
        )
        if proc.returncode != 0:
            raise RuntimeError(
                f"Bash expansion failed with code {proc.returncode}:\n"
                f"STDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}"
            )
        return proc.stdout


class TestAWGInboundConfig(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        find_bash()

    def test_awg_inbound_clients_configuration(self) -> None:
        fixture_client_priv = "TEST_CLIENT_PRIV_KEY_FIXTURE_12345678="
        fixture_client_pub = "TEST_CLIENT_PUB_KEY_FIXTURE_123456789="
        fixture_server_priv = "TEST_SERVER_PRIV_KEY_FIXTURE_12345678="
        fixture_server_pub = "TEST_SERVER_PUB_KEY_FIXTURE_123456789="

        variables: dict[str, str | int] = {
            "emoji_flag": "FLAG",
            "awg_port": "51820",
            "server_priv": fixture_server_priv,
            "server_pub": fixture_server_pub,
            "client_priv": fixture_client_priv,
            "client_pub": fixture_client_pub,
            "o_jc": 3,
            "o_jmin": 40,
            "o_jmax": 70,
            "o_s1": 15,
            "o_s2": 25,
            "o_s3": 35,
            "o_s4": 45,
            "o_h1": "1",
            "o_h2": "2",
            "o_h3": "3",
            "o_h4": "4",
            "o_i1": "5",
            "o_hpk": "test_hpk",
            "o_cp": "test_cp",
            "o_rka": "1",
            "o_rja": "2",
            "o_rt": "3",
            "o_ka": "4",
            "o_mha": "5",
        }

        raw_insert = extract_awg_inbound_insert(SCRIPT_PATH)
        expanded_sql = expand_awg_inbound_insert(raw_insert, variables)

        with tempfile.TemporaryDirectory(prefix="installer_sqlite_") as td:
            db_path = pathlib.Path(td) / "temp_xui.db"
            conn = sqlite3.connect(db_path)
            try:
                cur = conn.cursor()
                cur.execute(
                    """
                    CREATE TABLE inbounds (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        user_id INTEGER,
                        up INTEGER,
                        down INTEGER,
                        total INTEGER,
                        remark TEXT,
                        enable INTEGER,
                        expiry_time INTEGER,
                        listen TEXT,
                        port INTEGER,
                        protocol TEXT,
                        settings TEXT,
                        stream_settings TEXT,
                        tag TEXT,
                        sniffing TEXT
                    );
                    """
                )
                cur.execute(expanded_sql)
                conn.commit()

                cur.execute(
                    "SELECT settings FROM inbounds WHERE protocol = 'amneziawg'"
                )
                row = cur.fetchone()
                self.assertIsNotNone(row, "AWG inbound record was not inserted")
                settings: dict[str, Any] = json.loads(row[0])
            finally:
                conn.close()

        self.assertIn("clients", settings, "Missing 'clients' key in settings JSON")
        clients = settings["clients"]
        self.assertIsInstance(clients, list, "settings['clients'] must be a list")
        self.assertEqual(
            len(clients), 1, f"Expected exactly one client in AWG settings, got: {clients}"
        )

        client = clients[0]
        self.assertIsInstance(client, dict, "client entry must be a dictionary")
        self.assertEqual(client.get("email"), "first")
        self.assertEqual(client.get("subId"), "first")
        self.assertIs(client.get("enable"), True)
        self.assertEqual(client.get("privateKey"), fixture_client_priv)
        self.assertEqual(client.get("publicKey"), fixture_client_pub)
        self.assertEqual(client.get("allowedIPs"), ["10.8.1.2/32"])
        self.assertEqual(client.get("keepAlive"), 25)


if __name__ == "__main__":
    unittest.main()
