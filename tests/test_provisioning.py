import json
import pathlib
import re
import shlex
import sqlite3
import subprocess
import unittest

from test_installer import find_bash


ROOT = pathlib.Path(__file__).resolve().parent.parent


def provision(name: str) -> sqlite3.Connection:
    content = (ROOT / name).read_text(encoding="utf-8")
    block = content.split("UPDATE_XUIDB(){", 1)[1]
    match = re.search(r"sqlite3 (?:-bail )?\$XUIDB <<EOF\n(.*?)\nEOF", block, re.DOTALL)
    if not match:
        raise AssertionError("Provisioning SQL not found")
    sql = match.group(1)
    variables = set(re.findall(r"\$\{?(\w+)", sql))
    header = "\n".join(f"{key}=1" for key in sorted(variables - {"shor"}))
    header += '\nshor=(0123456789abcdef 0123456789abcdef 0123456789abcdef 0123456789abcdef '
    header += '0123456789abcdef 0123456789abcdef 0123456789abcdef 0123456789abcdef)\n'
    for index, key in enumerate(("sub_port", "ws_port", "trojan_port", "hy2_port", "awg_port", "xhttp_port")):
        header += f"{key}={30000 + index}\n"
    node_name = re.search(r"^\s*(node_name=.*)$", block, re.MULTILINE)
    if not node_name:
        raise AssertionError("Node name preparation not found")
    header += '\nemoji_flag=FLAG\ncountry=' + shlex.quote("Côte d'Ivoire") + '\n' + node_name.group(1) + '\n'
    result = subprocess.run(
        [find_bash()], input=header + "\ncat <<EOF\n" + sql + "\nEOF\n",
        capture_output=True, text=True, timeout=15,
    )
    if result.returncode:
        raise AssertionError(result.stderr)
    conn = sqlite3.connect(":memory:")
    conn.executescript("""
        CREATE TABLE settings (id INTEGER PRIMARY KEY AUTOINCREMENT, key TEXT, value TEXT);
        CREATE TABLE nodes (id INTEGER PRIMARY KEY, name TEXT, remark TEXT);
        INSERT INTO nodes VALUES (1, 'old', 'old');
        CREATE TABLE client_traffics (
            id INTEGER PRIMARY KEY AUTOINCREMENT, inbound_id INTEGER, enable INTEGER,
            email TEXT UNIQUE, up INTEGER, down INTEGER, expiry_time INTEGER, total INTEGER, reset INTEGER
        );
        CREATE TABLE clients (
            id INTEGER PRIMARY KEY AUTOINCREMENT, email TEXT UNIQUE, sub_id TEXT, uuid TEXT,
            password TEXT, auth TEXT, flow TEXT, limit_ip INTEGER, total_gb INTEGER, expiry_time INTEGER,
            enable INTEGER, tg_id INTEGER, reset INTEGER, created_at INTEGER, updated_at INTEGER,
            wg_private_key TEXT, wg_public_key TEXT, wg_allowed_ips TEXT, wg_keep_alive INTEGER
        );
        CREATE TABLE client_inbounds (
            id INTEGER PRIMARY KEY AUTOINCREMENT, client_id INTEGER, inbound_id INTEGER,
            flow_override TEXT, created_at INTEGER
        );
        CREATE TABLE inbounds (
            id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER, up INTEGER, down INTEGER,
            total INTEGER, remark TEXT, enable INTEGER, expiry_time INTEGER, listen TEXT,
            port INTEGER, protocol TEXT, settings TEXT, stream_settings TEXT, tag TEXT, sniffing TEXT
        );
    """)
    try:
        conn.executescript(result.stdout)
    except Exception:
        conn.close()
        raise
    return conn


class TestProvisioning(unittest.TestCase):
    def test_current_schema_and_protocols(self) -> None:
        for name in ("x-ui-pro.sh", "x-ui-latest.sh"):
            with self.subTest(script=name), provision(name) as conn:
                self.addCleanup(conn.close)
                rows = conn.execute("SELECT protocol, settings, stream_settings FROM inbounds").fetchall()
                self.assertEqual(len(rows), 5)
                self.assertEqual(conn.execute("SELECT count(*) FROM client_traffics").fetchone()[0], 1)
                self.assertEqual(conn.execute("SELECT count(*) FROM client_inbounds").fetchone()[0], 5)
                self.assertEqual(conn.execute("SELECT name FROM nodes WHERE id=1").fetchone()[0], "FLAG Côte d'Ivoire")
                self.assertEqual(conn.execute("""
                    SELECT count(*) FROM client_inbounds c LEFT JOIN inbounds i ON c.inbound_id = i.id
                    WHERE i.id IS NULL
                """).fetchone()[0], 0)
                settings = dict(conn.execute("SELECT key, value FROM settings"))
                self.assertEqual(settings["subJsonEnable"], "true")
                self.assertEqual(settings["subClashEnable"], "true")
                self.assertEqual(settings["webListen"], "127.0.0.1")
                for protocol, raw, stream in rows:
                    inbound = json.loads(raw)
                    json.loads(stream)
                    if protocol == "vless":
                        self.assertEqual(inbound["encryption"], "none")
                    elif protocol == "hysteria":
                        self.assertEqual(inbound["version"], 2)


if __name__ == "__main__":
    unittest.main()
