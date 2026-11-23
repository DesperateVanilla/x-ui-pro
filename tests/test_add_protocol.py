import base64
from concurrent.futures import ThreadPoolExecutor
import copy
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shlex
import shutil
import sqlite3
import ssl
import subprocess
import tempfile
import threading
import time
import unittest


SCRIPT = Path(__file__).resolve().parent.parent / "add_protocol.sh"
PRIVATE = base64.urlsafe_b64encode(bytes([251]) * 32).decode().rstrip("=")
PUBLIC = base64.urlsafe_b64encode(bytes([255]) * 32).decode().rstrip("=")
CLIENT_ID = "268ebcee-2a20-4ec3-a423-12a0e3bd6ad5"
OLD_TOKEN = "unrelated-operator-token-which-must-stay-untouched"
PREFIX = "/hidden/base/panel/api"


@unittest.skipUnless(os.name == "posix" and os.geteuid() == 0, "Requires a root shell on Linux")
class TestAddProtocol(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.database = self.root / "x-ui.db"
        self.nginx = self.root / "nginx"
        self.addCleanup(self.stop_server)
        self.requests = []
        self.tokens_seen = set()
        self.attach_error = False
        self.create_error = False
        self.clients = [{
            "email": "Клиент@example.test", "subId": "stable-subscription",
            "id": CLIENT_ID, "enable": True, "privateKey": "existing-legacy-private-key",
            "publicKey": "existing-legacy-public-key", "password": "existing-password", "inboundIds": [],
        }, {
            "email": "disabled@example.test", "subId": "another-subscription",
            "id": "f83ac67b-2b45-4fdc-a8ee-11a6b6e94a72", "enable": False, "inboundIds": [],
        }]
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), self.make_handler())
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.db = sqlite3.connect(self.database)
        self.addCleanup(self.db.close)
        self.db.executescript("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE users (id INTEGER PRIMARY KEY);
            INSERT INTO users VALUES (1);
            CREATE TABLE settings (id INTEGER PRIMARY KEY, key TEXT, value TEXT);
            CREATE TABLE api_tokens (
                id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE, token TEXT NOT NULL,
                enabled INTEGER NOT NULL, created_at INTEGER NOT NULL,
                scope TEXT NOT NULL, expires_at INTEGER NOT NULL
            );
            CREATE TABLE inbounds (
                id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, node_id INTEGER,
                protocol TEXT NOT NULL, stream_settings TEXT, port INTEGER NOT NULL, payload TEXT NOT NULL
            );
        """)
        self.set_settings({
            "webPort": str(self.server.server_port), "webListen": "127.0.0.1", "webBasePath": "/hidden/base/",
            "subURI": "https://www.example.test/sub/",
        })
        with self.db:
            self.db.execute("INSERT INTO api_tokens VALUES (47,'cli-fallback',?,1,10,'admin',0)", (OLD_TOKEN,))
        (self.nginx / "stream-enabled").mkdir(parents=True)
        (self.nginx / "snippets").mkdir()
        (self.nginx / "sites-enabled").mkdir()
        (self.nginx / "snippets/includes.conf").write_text(
            r"location ~ ^/(?<fwdport>\d+)/(?<fwdpath>.*)$ { proxy_pass http://127.0.0.1:$fwdport; }" + "\n",
        )
        self.cert = self.root / "fixture-cert.pem"
        self.key = self.root / "fixture-key.pem"
        self.cert.touch()
        self.key.touch()
        self.configure_nginx("www.example.test")
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine, os.uname().machine)
        self.fake_command(bin_dir / f"xray-linux-{arch}", f"""
            test "$1" = x25519 || exit 1
            printf '%s\n' 'PrivateKey: {PRIVATE}' 'Password (PublicKey): {PUBLIC}'
        """)
        self.ufw_calls = self.root / "ufw-calls"
        self.fake_command(bin_dir / "ufw", f"""
            if [ "$1" = status ]; then
                printf '%s\n' 'Status: active'
                exit 0
            fi
            printf '%s\n' "$*" >> {shlex.quote(str(self.ufw_calls))}
        """)
        self.env = {
            **os.environ, "XUI_DB_FOLDER": str(self.root), "XUI_BIN_FOLDER": str(bin_dir),
            "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"],
        }
        self.env.pop("XUI_PORT", None)

    def stop_server(self):
        if hasattr(self, "server"):
            self.server.shutdown()
            self.thread.join(timeout=2)
            self.server.server_close()

    def set_settings(self, settings):
        with self.db:
            for name, value in settings.items():
                self.db.execute("DELETE FROM settings WHERE key = ?", (name,))
                self.db.execute("INSERT INTO settings(key, value) VALUES (?, ?)", (name, value))

    def configure_nginx(self, host, ip=False):
        web_entry = "" if ip else f"  {host} www;\n"
        (self.nginx / "stream-enabled/stream.conf").write_text(
            "map $ssl_preread_server_name $sni_name {\n"
            "  camouflage.example.test xray;\n" + web_entry
            + ("  default www;\n" if ip else "  default xray;\n")
            + "}\nupstream xray { server 127.0.0.1:8443; }\n",
        )
        (self.nginx / "sites-enabled" / host).write_text(
            f"server {{\n listen 7443 ssl http2 proxy_protocol;\n server_name {host};\n"
            f" ssl_certificate {self.cert};\n ssl_certificate_key {self.key};\n}}\n",
        )

    @staticmethod
    def fake_command(path, script):
        path.write_text("#!/bin/sh\n" + script)
        path.chmod(0o755)

    def seed(self, protocol, network, security, port, *, node=None, enabled=True):
        stream = None if network is None else {"network": network, "security": security}
        payload = {"protocol": protocol, "streamSettings": stream, "port": port,
                   "enable": enabled, "listen": "", "settings": {"clients": []}}
        if node is not None:
            payload["nodeId"] = node
        with self.db:
            cursor = self.db.execute(
                "INSERT INTO inbounds(user_id,node_id,protocol,stream_settings,port,payload) VALUES (1,?,?,?,?,?)",
                (node, protocol, json.dumps(stream) if stream else None, port, json.dumps(payload)),
            )
            return cursor.lastrowid

    def stored_inbounds(self):
        return self.inbounds(self.db)

    @staticmethod
    def inbounds(db):
        entries = []
        for inbound_id, payload in db.execute("SELECT id, payload FROM inbounds ORDER BY id"):
            entries.append({"id": inbound_id, **json.loads(payload)})
        return entries

    def run_recovery(self, *args):
        script = SCRIPT.read_text(encoding="utf-8").replace(
            'NGINX_ROOT = Path("/etc/nginx")', f"NGINX_ROOT = Path({str(self.nginx)!r})",
        )
        return subprocess.run(
            ["bash", "-s", "--", *args], input=script, env=self.env, text=True, capture_output=True, timeout=45,
        )

    def make_handler(self):
        case = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                return

            def reply(self, success, obj=None, msg="", status=200):
                result = json.dumps({"success": success, "msg": msg, "obj": obj}).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(result)))
                self.end_headers()
                self.wfile.write(result)

            def do_GET(self):
                self.dispatch()

            def do_POST(self):
                self.dispatch()

            def dispatch(self):
                if not self.path.startswith(PREFIX):
                    self.reply(False, status=404)
                    return
                token = self.headers.get("Authorization", "").removeprefix("Bearer ")
                digest = hashlib.sha256(token.encode()).hexdigest()
                with sqlite3.connect(case.database) as db:
                    expiry = db.execute(
                        "SELECT expires_at FROM api_tokens WHERE token = ? AND enabled = 1 AND scope = 'admin'",
                        (digest,),
                    ).fetchone()
                    now = int(time.time() * 1000)
                    if not expiry or not now < expiry[0] <= now + 60_000:
                        self.reply(False, status=401)
                        return
                    case.tokens_seen.add(token)
                    path = self.path.removeprefix(PREFIX)
                    data = json.loads(self.rfile.read(int(self.headers["Content-Length"]))) if self.command == "POST" else None
                    case.requests.append((self.command, path, data))
                    if self.command == "GET" and path == "/inbounds/list/slim":
                        self.reply(True, case.inbounds(db))
                    elif self.command == "GET" and path == "/clients/list":
                        self.reply(True, case.clients)
                    elif self.command == "POST" and path == "/inbounds/add":
                        self.add_inbound(db, data)
                    elif self.command == "POST" and path == "/clients/bulkAttach":
                        self.attach(db, data)
                    elif self.command == "POST" and path.startswith("/inbounds/del/"):
                        identifier = int(path.rsplit("/", 1)[-1])
                        db.execute("DELETE FROM inbounds WHERE id = ?", (identifier,))
                        for client in case.clients:
                            client["inboundIds"] = [n for n in client["inboundIds"] if n != identifier]
                        db.commit()
                        self.reply(True, identifier)
                    else:
                        self.reply(False, status=404)

            def add_inbound(self, db, data):
                if case.create_error:
                    self.reply(False, msg=f"Rejected {PRIVATE} {CLIENT_ID}")
                    return
                if (not isinstance(data["settings"], dict) or data["settings"].get("clients") != []
                    or not isinstance(data["streamSettings"], dict) or not data["enable"]
                    or data.get("nodeId")):
                    self.reply(False, msg="Invalid inbound shape")
                    return
                data = copy.deepcopy(data)
                if data["protocol"] == "amneziawg":
                    data["streamSettings"] = None
                cursor = db.execute(
                    "INSERT INTO inbounds(user_id,node_id,protocol,stream_settings,port,payload) "
                    "VALUES (1,NULL,?,?,?,?)",
                    (data["protocol"], json.dumps(data["streamSettings"]) if data["streamSettings"] else None,
                     data["port"], json.dumps(data)),
                )
                db.commit()
                self.reply(True, {"id": cursor.lastrowid, **data})

            def attach(self, db, data):
                inbound = data["inboundIds"]
                if len(inbound) != 1 or not db.execute("SELECT 1 FROM inbounds WHERE id = ?", inbound).fetchone():
                    self.reply(False, msg="Unknown inbound")
                    return
                attached, skipped = [], []
                for client in case.clients:
                    if client["email"] not in data["emails"]:
                        continue
                    if inbound[0] in client["inboundIds"]:
                        skipped.append(client["email"])
                    else:
                        client["inboundIds"].extend(inbound)
                        attached.append(client["email"])
                    if case.attach_error:
                        break
                errors = [f"Rejected {PRIVATE} {CLIENT_ID}"] if case.attach_error else None
                self.reply(True, {"attached": attached or None, "skipped": skipped or None, "errors": errors})

        return Handler

    def verify_secret_cleanup(self, result):
        output = result.stdout + result.stderr
        for secret in (PRIVATE, PUBLIC, CLIENT_ID, OLD_TOKEN, *self.tokens_seen):
            self.assertNotIn(secret, output)
        self.assertEqual(
            self.db.execute("SELECT id, name, token, expires_at FROM api_tokens").fetchall(),
            [(47, "cli-fallback", OLD_TOKEN, 0)],
        )

    def test_complete_recovery_and_repeat_noop(self):
        original = copy.deepcopy(self.clients)
        result = self.run_recovery()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.verify_secret_cleanup(result)
        self.assertEqual(len(self.stored_inbounds()), 6)
        all_ids = [row["id"] for row in self.stored_inbounds()]
        for client, before in zip(self.clients, original):
            self.assertEqual(client, {**before, "inboundIds": all_ids})
        creates = [payload for method, path, payload in self.requests if path == "/inbounds/add"]
        reality, ws, xhttp, grpc, hy2, awg = creates
        reality_settings = reality["streamSettings"]["realitySettings"]
        self.assertEqual(reality_settings["privateKey"], PRIVATE)
        self.assertEqual(reality_settings["settings"]["publicKey"], PUBLIC)
        self.assertEqual(reality_settings["target"], "127.0.0.1:9443")
        self.assertEqual(reality_settings["serverNames"], ["camouflage.example.test"])
        self.assertEqual(reality["port"], 8443)
        for inbound, field, key in ((ws, "wsSettings", "path"), (xhttp, "xhttpSettings", "path"),
                                    (grpc, "grpcSettings", "serviceName")):
            stream = inbound["streamSettings"]
            self.assertRegex(stream[field][key], rf"^/{inbound['port']}/[0-9a-f]+$")
            self.assertEqual(inbound["listen"], "127.0.0.1")
            self.assertEqual(stream["security"], "none")
            self.assertEqual(stream["externalProxy"][0]["port"], 443)
        self.assertEqual(hy2["settings"]["version"], 2)
        self.assertEqual(hy2["streamSettings"]["hysteriaSettings"]["version"], 2)
        self.assertEqual(hy2["streamSettings"]["tlsSettings"]["certificates"][0]["certificateFile"], str(self.cert))
        self.assertEqual(awg["shareAddr"], "www.example.test")
        server = awg["settings"]["server"]
        self.assertEqual(server["privateKey"], base64.b64encode(bytes([251]) * 32).decode())
        self.assertEqual(server["publicKey"], base64.b64encode(bytes([255]) * 32).decode())
        self.assertEqual(len(base64.b64decode(server["headerProtectionKey"], validate=True)), 32)
        bands = [list(map(int, server[f"h{i}"].split("-"))) for i in range(1, 5)]
        self.assertTrue(all(bands[i][1] < bands[i + 1][0] for i in range(3)))
        self.assertTrue(server["randomTrailers"] and server["disableCookies"])
        self.assertEqual(set(self.ufw_calls.read_text().splitlines()),
                         {f"allow {hy2['port']}/udp", f"allow {awg['port']}/udp"})
        backups = list(self.root.glob("x-ui.db.add-protocol-*.bak"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].stat().st_mode & 0o777, 0o600)
        with sqlite3.connect(backups[0]) as backup:
            self.assertEqual(backup.execute("SELECT count(*) FROM inbounds").fetchone()[0], 0)
            self.assertEqual(backup.execute("SELECT token FROM api_tokens").fetchall(), [(OLD_TOKEN,)])
        before = list(self.requests)
        repeated = self.run_recovery("all")
        self.assertEqual(repeated.returncode, 0, repeated.stderr)
        self.assertEqual(self.requests, before)
        self.assertEqual(list(self.root.glob("x-ui.db.add-protocol-*.bak")), backups)
        self.verify_secret_cleanup(repeated)

    def test_recovery_preserves_existing_disabled_and_remote_inbounds(self):
        disabled = self.seed("vless", "ws", "none", 10013, enabled=False)
        remote = self.seed("vless", "xhttp", "none", 10014, node=8)
        self.seed("vless", "raw", "reality", 8443)
        self.seed("trojan", "grpc", "none", 10015)
        self.seed("hysteria", "hysteria", "tls", 10016)
        self.seed("amneziawg", None, None, 10017)
        existing = self.stored_inbounds()
        self.clients[0]["inboundIds"] = [disabled, remote]
        result = self.run_recovery()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.stored_inbounds()[:-1], existing)
        self.assertEqual(self.stored_inbounds()[-1]["streamSettings"]["network"], "xhttp")
        self.assertEqual(self.clients[0]["inboundIds"], [disabled, remote, self.stored_inbounds()[-1]["id"]])
        self.verify_secret_cleanup(result)

    def test_awg_without_clients_and_concurrent_repeat(self):
        self.clients.clear()
        with ThreadPoolExecutor(max_workers=2) as pool:
            runs = [pool.submit(self.run_recovery, "awg") for _ in range(2)]
            results = [run.result() for run in runs]
        for result in results:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.verify_secret_cleanup(result)
        self.assertEqual(len(self.stored_inbounds()), 1)
        self.assertEqual(self.stored_inbounds()[0]["protocol"], "amneziawg")
        self.assertEqual(sum(path == "/inbounds/add" for _, path, _ in self.requests), 1)
        self.assertFalse(any(path == "/clients/bulkAttach" for _, path, _ in self.requests))

    def test_bulk_attach_error_rolls_back_new_inbound_for_retry(self):
        existing = self.seed("vless", "ws", "none", 10013)
        self.clients[0]["inboundIds"] = [existing]
        self.attach_error = True
        result = self.run_recovery("grpc")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("/clients/bulkAttach", result.stderr)
        self.assertEqual([inbound["id"] for inbound in self.stored_inbounds()], [existing])
        self.assertEqual(self.clients[0]["inboundIds"], [existing])
        self.verify_secret_cleanup(result)
        self.attach_error = False
        retry = self.run_recovery("trojan")
        self.assertEqual(retry.returncode, 0, retry.stderr)
        self.assertEqual(len(self.stored_inbounds()), 2)
        self.assertEqual(self.clients[0]["inboundIds"], [existing, self.stored_inbounds()[-1]["id"]])
        self.verify_secret_cleanup(retry)

    def test_add_error_returns_nonzero_and_stops(self):
        self.create_error = True
        result = self.run_recovery("all")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("/inbounds/add rejected", result.stderr)
        self.assertEqual(self.stored_inbounds(), [])
        self.assertEqual(sum(path == "/inbounds/add" for _, path, _ in self.requests), 1)
        self.assertFalse(any(path == "/clients/bulkAttach" for _, path, _ in self.requests))
        self.verify_secret_cleanup(result)

    @unittest.skipUnless(shutil.which("openssl"), "Requires openssl")
    def test_ip_mode_uses_public_ip_and_existing_certificate(self):
        host = "203.0.113.8"
        self.set_settings({"subURI": f"http://{host}/sub/"})
        self.configure_nginx(host, ip=True)
        subprocess.run(
            ["openssl", "req", "-x509", "-nodes", "-days", "1", "-newkey", "rsa:2048",
             "-subj", f"/CN={host}", "-keyout", self.key, "-out", self.cert],
            check=True, capture_output=True,
        )
        result = self.run_recovery("all")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.verify_secret_cleanup(result)
        creates = [payload for _, path, payload in self.requests if path == "/inbounds/add"]
        reality, ws, _, _, hy2, _ = creates
        self.assertEqual(reality["streamSettings"]["realitySettings"]["target"], "camouflage.example.test:443")
        pin = base64.b64encode(hashlib.sha256(ssl.PEM_cert_to_DER_cert(self.cert.read_text())).digest()).decode()
        for inbound in (ws, hy2):
            proxy = inbound["streamSettings"]["externalProxy"][0]
            self.assertEqual(proxy["dest"], host)
            self.assertEqual(proxy["pinnedPeerCertSha256"], [pin])


if __name__ == "__main__":
    unittest.main()
