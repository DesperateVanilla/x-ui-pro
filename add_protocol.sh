#!/bin/bash
set +x
exec python3 - "$@" <<'PY'
import base64
from contextlib import closing
import fcntl
import hashlib
import http.client
import ipaddress
import json
import os
from pathlib import Path
import random
import re
import secrets
import shutil
import signal
import socket
import sqlite3
import ssl
import subprocess
import sys
import tempfile
import time
from urllib.parse import quote, urlsplit


PROTOCOLS = {
    "reality": ("vless", "tcp", "reality"),
    "ws": ("vless", "ws", "none"),
    "xhttp": ("vless", "xhttp", "none"),
    "trojan": ("trojan", "grpc", "none"),
    "hy2": ("hysteria", "hysteria", "tls"),
    "awg": ("amneziawg", "amneziawg", "none"),
}
NGINX_ROOT = Path("/etc/nginx")
REALITY_PORT = 8443
REALITY_TARGET = "127.0.0.1:9443"


class RecoveryError(Exception):
    pass


def as_object(value):
    if value in (None, ""):
        return {}
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except ValueError:
            raise RecoveryError("An inbound has invalid JSON settings.") from None
    if not isinstance(value, dict):
        raise RecoveryError("An inbound has invalid settings.")
    return value


def fingerprint(inbound):
    protocol = inbound["protocol"]
    if protocol == "amneziawg":
        # The panel clears streamSettings when creating AmneziaWG inbounds.
        return PROTOCOLS["awg"]
    stream = as_object(inbound.get("streamSettings"))
    network = stream.get("method") or stream.get("network") or "tcp"
    network = {"raw": "tcp", "splithttp": "xhttp"}.get(network, network)
    return protocol, network, stream.get("security") or "none"


def missing_protocols(inbounds, selected):
    relevant = {PROTOCOLS[name][0] for name in selected}
    available = {fingerprint(inbound) for inbound in inbounds if inbound["protocol"] in relevant}
    return [name for name in selected if PROTOCOLS[name] not in available]


def local_inbound(inbound):
    return inbound.get("nodeId") in (None, "", 0, "0")


def db_connect(db_path, mode):
    return sqlite3.connect(db_path.resolve().as_uri() + "?mode=" + mode, uri=True, timeout=10)


def backup_database(source, db_path):
    fd, filename = tempfile.mkstemp(prefix=db_path.name + ".add-protocol-", suffix=".bak", dir=db_path.parent)
    os.close(fd)
    try:
        with closing(sqlite3.connect(filename)) as destination:
            source.backup(destination)
    except BaseException:
        Path(filename).unlink()
        raise
    return Path(filename)


def api_endpoint(settings):
    listen = settings.get("webListen", "").strip()
    host = "127.0.0.1" if listen in ("", "0.0.0.0", "::", "localhost") else listen
    try:
        address = ipaddress.ip_address(host)
        family = socket.AF_INET6 if address.version == 6 else socket.AF_INET
        with socket.socket(family, socket.SOCK_STREAM) as check:
            check.bind((host, 0))
        port = int(os.environ.get("XUI_PORT") or settings.get("webPort") or "2053")
        if not 0 < port < 65536:
            raise ValueError
    except (OSError, ValueError):
        raise RecoveryError("The panel API address is not a valid local listener.") from None
    base_path = "/" + quote(settings.get("webBasePath", "").strip("/"), safe="/")
    context = None
    if settings.get("webCertFile") and settings.get("webKeyFile"):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_flags |= ssl.VERIFY_X509_PARTIAL_CHAIN
        context.load_verify_locations(cafile=settings["webCertFile"])
    return host, port, base_path.rstrip("/") + "/panel/api", context


class PanelAPI:
    def __init__(self, db, endpoint):
        self.db = db
        self.host, self.port, self.base_path, self.context = endpoint
        self.name = "add-protocol-" + secrets.token_hex(12)
        self.token = secrets.token_urlsafe(36)
        self.digest = hashlib.sha256(self.token.encode()).hexdigest()
        self.expires = int(time.time() * 1000) + 60_000

    def __enter__(self):
        now = int(time.time())
        with self.db:
            self.db.execute(
                "INSERT INTO api_tokens (name, token, enabled, created_at, scope, expires_at) VALUES (?, ?, 1, ?, 'admin', ?)",
                (self.name, self.digest, now, self.expires),
            )
        return self

    def __exit__(self, exc_type, exc, traceback):
        with self.db:
            self.db.execute("DELETE FROM api_tokens WHERE name = ? AND token = ?", (self.name, self.digest))

    def call(self, route, body=None):
        now = int(time.time() * 1000)
        if self.expires - now < 35_000:
            self.expires = now + 60_000
            with self.db:
                self.db.execute(
                    "UPDATE api_tokens SET expires_at = ? WHERE name = ? AND token = ?",
                    (self.expires, self.name, self.digest),
                )
        method = "GET" if body is None else "POST"
        connection = (
            http.client.HTTPSConnection(self.host, self.port, timeout=30, context=self.context)
            if self.context
            else http.client.HTTPConnection(self.host, self.port, timeout=30)
        )
        label = f"Panel API {method} {route}"
        try:
            with closing(connection):
                connection.request(
                    method, self.base_path + route,
                    body=None if body is None else json.dumps(body),
                    headers={
                        "Authorization": "Bearer " + self.token,
                        "Content-Type": "application/json",
                        "X-Requested-With": "XMLHttpRequest",
                    },
                )
                response = connection.getresponse()
                if response.status != 200:
                    raise RecoveryError(f"{label} returned HTTP {response.status}.")
                result = json.load(response)
        except (OSError, ValueError, http.client.HTTPException):
            raise RecoveryError(f"{label} could not be completed.") from None
        if not isinstance(result, dict) or result.get("success") is not True:
            message = result.get("msg") if isinstance(result, dict) else None
            if isinstance(message, str) and "exceeds the relay port window" in message:
                raise RecoveryError("The panel rejected the AmneziaWG inbound ID outside its relay port window.")
            raise RecoveryError(f"{label} rejected the request.")
        return result.get("obj")


def api_list(api, route):
    items = api.call(route)
    if not isinstance(items, list) or any(not isinstance(item, dict) for item in items):
        raise RecoveryError(f"Panel API GET {route} returned an invalid list.")
    return items


def nginx_text(path):
    try:
        return path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return ""


def normalized_host(value):
    value = value.strip().strip("[]").rstrip(".").lower()
    try:
        return str(ipaddress.ip_address(value))
    except ValueError:
        return value if re.fullmatch(r"[a-z0-9][a-z0-9.-]*[a-z0-9]", value) else ""


def url_host(value):
    if not value:
        return ""
    return normalized_host(urlsplit(value if "://" in value else "//" + value).hostname or "")


def public_route(settings):
    stream = nginx_text(NGINX_ROOT / "stream-enabled/stream.conf")
    routes = {}
    for hostname, backend in re.findall(r"(?m)^\s*([^\s;{}]+)[ \t]+(xray|www)[ \t]*;", stream):
        host = normalized_host(hostname.strip("\"'"))
        if host and host != "default":
            routes.setdefault(backend, host)
    public = routes.get("www") or url_host(settings.get("subURI")) or url_host(settings.get("webDomain"))
    return public, routes.get("xray")


def public_certificate(address):
    names = (NGINX_ROOT / "sites-enabled", NGINX_ROOT / "sites-available")
    for directory in names:
        site = nginx_text(directory / address)
        cert = re.search(r"(?m)^\s*ssl_certificate[ \t]+([^;\n]+);", site)
        key = re.search(r"(?m)^\s*ssl_certificate_key[ \t]+([^;\n]+);", site)
        if cert and key:
            files = [match.group(1).strip().strip("\"'") for match in (cert, key)]
            if all(Path(path).is_file() for path in files):
                return files
    fallback = Path("/etc/letsencrypt/live") / address
    files = [fallback / "fullchain.pem", fallback / "privkey.pem"]
    if all(path.is_file() for path in files):
        return [str(path) for path in files]
    raise RecoveryError("The existing public TLS certificate or key could not be found.")


def self_signed_pin(cert):
    info = subprocess.run(
        ["openssl", "x509", "-in", cert, "-noout", "-subject", "-issuer", "-nameopt", "RFC2253"],
        capture_output=True, text=True, timeout=10,
    )
    fields = dict(line.split("=", 1) for line in info.stdout.splitlines() if "=" in line)
    if info.returncode or not fields.get("subject") or not fields.get("issuer"):
        raise RecoveryError("The public TLS certificate could not be read.")
    if fields["subject"] != fields["issuer"]:
        return None
    pem = Path(cert).read_text(encoding="ascii").split("-----END CERTIFICATE-----", 1)[0]
    leaf = ssl.PEM_cert_to_DER_cert(pem + "-----END CERTIFICATE-----")
    return base64.b64encode(hashlib.sha256(leaf).digest()).decode()


def is_ip(host):
    try:
        ipaddress.ip_address(host)
        return True
    except ValueError:
        return False


def xray_keys(wireguard=False):
    bin_dir = Path(os.environ.get("XUI_BIN_FOLDER", "/usr/local/x-ui/bin"))
    machine = os.uname().machine
    arch = {"x86_64": "amd64", "x64": "amd64", "aarch64": "arm64", "arm": "arm32"}.get(machine, machine)
    if re.fullmatch(r"i[3-6]86", machine) or machine == "x86":
        arch = "386"
    elif machine.startswith("armv8"):
        arch = "arm64"
    elif re.match(r"armv[5-7]", machine):
        arch = "arm32"
    names = [f"xray-linux-{arch}", f"xray-linux-{machine}", f"xray-linux-{machine.removesuffix('l')}", "xray"]
    binary = next((bin_dir / name for name in names if (bin_dir / name).is_file()), None)
    if binary is None:
        raise RecoveryError("The installed Xray binary could not be found.")
    result = subprocess.run([binary, "x25519"], capture_output=True, text=True, timeout=10)
    if result.returncode:
        raise RecoveryError("Xray could not generate an X25519 key pair.")
    private = re.search(r"(?im)^\s*Private(?:\s*Key)?\s*:\s*(\S+)", result.stdout)
    public = re.search(r"(?im)^\s*Public(?:\s*Key)?\s*:\s*(\S+)", result.stdout)
    public = public or re.search(r"(?im)^\s*Password(?:\s*\([^\n]*?\))?\s*:\s*(\S+)", result.stdout)
    if not private or not public:
        raise RecoveryError("Xray returned an unrecognized X25519 key pair.")

    def encode(match):
        value = match.group(1)
        decoded = base64.b64decode(value + "=" * (-len(value) % 4), altchars=b"-_", validate=True)
        if len(decoded) != 32:
            raise ValueError
        if wireguard:
            return base64.b64encode(decoded).decode()
        return base64.urlsafe_b64encode(decoded).decode().rstrip("=")

    try:
        return encode(private), encode(public)
    except ValueError:
        raise RecoveryError("Xray returned invalid X25519 keys.") from None


def awg_settings():
    private, public = xray_keys(wireguard=True)
    rand = random.SystemRandom().randint

    def bounds(start, width):
        return f"{start}-{start + width}"

    jmin = rand(40, 89)
    s1, s2 = rand(15, 150), rand(15, 150)
    while s1 + 56 == s2:
        s2 = rand(15, 150)
    h = {}
    band = (2**31 - 5) // 4
    for i in range(4):
        lo, hi = 5 + i * band, 5 + (i + 1) * band - 1
        start = rand(lo, hi - 101)
        h[f"h{i + 1}"] = f"{start}-{rand(start + 100, hi - 1)}"
    rekey = rand(100, 120)
    rekey_width = rand(10, 40)
    return {
        "privateKey": private, "publicKey": public,
        "subnetIp": "10.8.1.0", "subnetCidr": 24, "mtu": 1280,
        "primaryDns": "8.8.8.8", "secondaryDns": "8.8.4.4",
        "jc": rand(3, 6), "jmin": jmin, "jmax": jmin + rand(50, 250),
        "s1": s1, "s2": s2, "s3": rand(12, 55), "s4": rand(12, 27), **h,
        "i1": f"<r {rand(32, 256)}>",
        "headerProtectionKey": base64.b64encode(secrets.token_bytes(32)).decode(),
        "contentPaddingAddition": bounds(rand(8, 24), rand(8, 40)),
        "rekeyAfterTime": bounds(rekey, rekey_width),
        "rejectAfterTime": bounds(rekey + rekey_width + rand(30, 60), rand(30, 90)),
        "rekeyTimeout": bounds(rand(3, 6), rand(1, 4)),
        "keepaliveTimeout": bounds(rand(8, 12), rand(2, 8)),
        "maxHandshakeAttempts": bounds(rand(15, 25), rand(5, 25)),
        "randomTrailers": True, "disableCookies": True,
    }


def reserve_port(used, name, udp, listen):
    if name == "reality":
        candidates = [REALITY_PORT]
    else:
        candidates = random.SystemRandom().sample(range(10000, 60000), 128)
    for port in candidates:
        if port in used:
            continue
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM if udp else socket.SOCK_STREAM) as check:
                check.bind((listen or "0.0.0.0", port))
        except OSError:
            continue
        used.add(port)
        return port
    raise RecoveryError(f"No available port for {name}.")


def plan_inbounds(selected, settings, inbounds):
    address, sni = public_route(settings)
    if any(name != "awg" for name in selected) and not address:
        raise RecoveryError("The installer's public domain or IP address could not be determined.")
    ip_mode = is_ip(address)
    tls_transports = {"ws", "xhttp", "trojan"}
    if tls_transports.intersection(selected):
        if "fwdport" not in nginx_text(NGINX_ROOT / "snippets/includes.conf"):
            raise RecoveryError("The installer's Nginx forwarding configuration could not be found.")
    cert = key = pin = None
    if "hy2" in selected or (ip_mode and tls_transports.intersection(selected)):
        cert, key = public_certificate(address)
        if ip_mode:
            pin = self_signed_pin(cert)

    occupied = {row["port"] for row in inbounds}
    if "reality" not in selected:
        occupied.add(REALITY_PORT)
    results = []
    for name in selected:
        protocol, network, security = PROTOCOLS[name]
        udp = name in ("hy2", "awg")
        listen = "" if udp else "127.0.0.1"
        port = reserve_port(occupied, name, udp, listen)
        path = f"/{port}/{secrets.token_hex(6)}"
        config = {"clients": []}
        stream = {"network": network, "security": security}
        if protocol == "vless":
            config.update(decryption="none", encryption="none", fallbacks=[])
        if protocol == "trojan":
            config["fallbacks"] = []
        if name != "awg":
            proxy = {"forceTls": "same" if name == "reality" else "tls", "dest": address}
            proxy["port"] = port if name == "hy2" else 443
            if name != "reality" and not ip_mode:
                proxy["sni"] = address
            if pin and name != "reality":
                proxy["pinnedPeerCertSha256"] = [pin]
            stream["externalProxy"] = [proxy]
        if name == "reality":
            fallback = next((
                as_object(row.get("streamSettings")).get("realitySettings", {})
                for row in inbounds
                if row["protocol"] == "vless"
                and as_object(row.get("streamSettings")).get("security") == "reality"
            ), {})
            sni = sni or next(iter(fallback.get("serverNames") or []), None)
            if not sni:
                raise RecoveryError("The Reality server name could not be read from the existing configuration.")
            target = (fallback.get("target") or f"{sni}:443") if ip_mode else REALITY_TARGET
            private, public = xray_keys()
            stream["realitySettings"] = {
                "target": target, "serverNames": [sni], "privateKey": private,
                "xver": 0, "shortIds": [secrets.token_hex(8) for _ in range(8)],
                "settings": {"publicKey": public, "fingerprint": "chrome", "serverName": sni, "spiderX": "/"},
            }
            stream["tcpSettings"] = {"acceptProxyProtocol": True, "header": {"type": "none"}}
        elif name == "ws":
            stream["wsSettings"] = {"path": path, "host": address, "headers": {}}
        elif name == "xhttp":
            stream["xhttpSettings"] = {
                "path": path, "host": address, "headers": {}, "mode": "auto",
                "scMaxBufferedPosts": 30, "scMaxEachPostBytes": "1000000", "xPaddingBytes": "100-1000",
            }
        elif name == "trojan":
            stream["grpcSettings"] = {"serviceName": path, "authority": address, "multiMode": False}
        elif name == "hy2":
            config.update(version=2, ignoreClientBandwidth=False)
            stream["hysteriaSettings"] = {"version": 2, "udpIdleTimeout": 300}
            stream["tlsSettings"] = {
                "serverName": address, "alpn": ["h3"],
                "certificates": [{"useFile": True, "certificateFile": cert, "keyFile": key}],
            }
        elif name == "awg":
            config["server"] = awg_settings()
        body = {
            "remark": {"trojan": "trojan-grpc", "hy2": "hysteria2", "awg": "amneziawg"}.get(name, name),
            "enable": True, "protocol": protocol, "listen": listen, "port": port, "tag": f"inbound-{port}",
            "settings": config, "streamSettings": stream, "sniffing": {"enabled": False},
        }
        if name == "awg" and address:
            body.update(shareAddrStrategy="custom", shareAddr=address)
        results.append((name, body))
    return results


def firewall_command():
    ufw = shutil.which("ufw")
    if not ufw:
        return None
    env = {**os.environ, "LC_ALL": "C"}
    result = subprocess.run([ufw, "status"], capture_output=True, text=True, env=env, timeout=15)
    if result.returncode:
        raise RecoveryError("Could not check UFW status.")
    return ufw if re.search(r"(?m)^Status: active\s*$", result.stdout) else None


def create_inbound(api, name, body, emails, ufw):
    created = api.call("/inbounds/add", body)
    inbound_id = created.get("id") if isinstance(created, dict) else None
    if type(inbound_id) is not int or inbound_id <= 0:
        raise RecoveryError(f"The panel returned no inbound ID for {name}.")
    try:
        if emails:
            result = api.call("/clients/bulkAttach", {"emails": emails, "inboundIds": [inbound_id]})
            if not isinstance(result, dict) or result.get("errors"):
                count = len(result.get("errors") or []) if isinstance(result, dict) else len(emails)
                raise RecoveryError(f"Panel API /clients/bulkAttach failed for {name} ({count} errors).")
            attached = (result.get("attached") or []) + (result.get("skipped") or [])
            if set(attached) != set(emails):
                raise RecoveryError(f"Panel API /clients/bulkAttach omitted clients for {name}.")
        if ufw and name in ("hy2", "awg"):
            result = subprocess.run([ufw, "allow", f"{body['port']}/udp"], capture_output=True, timeout=15)
            if result.returncode:
                raise RecoveryError(f"Could not open the UFW UDP port for {name}.")
    except (RecoveryError, OSError, TypeError, KeyboardInterrupt, subprocess.SubprocessError):
        try:
            api.call(f"/inbounds/del/{inbound_id}", {})
        except RecoveryError:
            raise RecoveryError(
                f"Setup failed for {name} and the panel could not remove its new inbound #{inbound_id}."
            ) from None
        print(f"Removed incomplete {name} inbound #{inbound_id}.", file=sys.stderr)
        raise
    print(f"Added {name} on port {body['port']} ({len(emails)} linked clients).")


def recover(selected):
    db_path = Path(os.environ.get("XUI_DB_FOLDER", "/etc/x-ui")) / "x-ui.db"
    if not db_path.is_file():
        raise RecoveryError("The installed SQLite database x-ui.db could not be found.")
    # flock coordinates this script's runs without taking SQLite's write lock.
    with db_path.open("rb") as lock, closing(db_connect(db_path, "ro")) as source:
        fcntl.flock(lock, fcntl.LOCK_EX)
        owner = source.execute("SELECT id FROM users ORDER BY id LIMIT 1").fetchone()
        if owner is None:
            raise RecoveryError("The panel has no administrator.")
        existing = [
            {"protocol": protocol, "streamSettings": stream}
            for protocol, stream in source.execute(
                "SELECT protocol, stream_settings FROM inbounds WHERE user_id = ? "
                "AND (node_id IS NULL OR node_id IN (0, ''))",
                owner,
            )
        ]
        wanted = missing_protocols(existing, selected)
        if not wanted:
            print("Already present: " + ", ".join(selected) + ".")
            return

        settings = dict(source.execute(
            "SELECT key, value FROM settings WHERE key IN "
            "('webListen','webPort','webBasePath','webCertFile','webKeyFile','webDomain','subURI') ORDER BY id DESC"
        ))
        endpoint = api_endpoint(settings)
        print(f"Database backup: {backup_database(source, db_path)}")
        with closing(db_connect(db_path, "rw")) as db, PanelAPI(db, endpoint) as api:
            inbounds = [row for row in api_list(api, "/inbounds/list/slim") if local_inbound(row)]
            wanted = missing_protocols(inbounds, selected)
            for name in selected:
                if name not in wanted:
                    print(f"Already present: {name}.")
            if not wanted:
                return
            clients = api_list(api, "/clients/list")
            emails = [row.get("email") for row in clients]
            if any(not isinstance(email, str) or not email for email in emails):
                raise RecoveryError("The client list contains a record with no email.")
            plans = plan_inbounds(wanted, settings, inbounds)
            ufw = firewall_command() if {"awg", "hy2"}.intersection(wanted) else None
            for name, body in plans:
                create_inbound(api, name, body, emails, ufw)


def interrupted(signum, frame):
    raise KeyboardInterrupt


def main():
    usage = "Usage: bash add_protocol.sh [all|reality|ws|xhttp|trojan|hy2|awg]"
    args = sys.argv[1:]
    if args in (["--help"], ["-h"]):
        print(usage)
        return 0
    name = args[0].lower() if args else "all"
    name = {"grpc": "trojan", "trojan-grpc": "trojan", "trojan/grpc": "trojan"}.get(name, name)
    if len(args) > 1 or (name != "all" and name not in PROTOCOLS):
        print(usage, file=sys.stderr)
        return 2
    if os.geteuid() != 0:
        print("Run this script as root.", file=sys.stderr)
        return 1
    signal.signal(signal.SIGTERM, interrupted)
    try:
        recover(list(PROTOCOLS) if name == "all" else [name])
    except RecoveryError as err:
        print(f"Error: {err}", file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError, TypeError, sqlite3.Error, subprocess.SubprocessError):
        print("Error: Could not read the local configuration or complete protocol recovery.", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("Protocol recovery interrupted.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
