#!/usr/bin/env python3
"""Aegis helper: wraps adguardvpn-cli and prints exactly one JSON object.

    python3 agvpn.py snapshot
    python3 agvpn.py locations
    python3 agvpn.py connect <cliName>
    python3 agvpn.py disconnect
    python3 agvpn.py account
    python3 agvpn.py logout
    python3 agvpn.py exclusions show | mode <general|selective> | add <domain> | remove <domain>
    python3 agvpn.py home
    python3 agvpn.py config show | set <key> <value>
    python3 agvpn.py update-check
    python3 agvpn.py kill <name> [name...]

Always exits 0. Success is {"ok": true, ...}; failure is
{"ok": false, "error": "<=160 chars", "code": "<cli_missing|logged_out|sudo_password|timeout|parse|network|unknown>"}.
The CLI has no machine-readable output and always emits ANSI colour, so every
read goes through strip_ansi() and a fixed-width or regex parser tested
against recorded fixtures in tests/fixtures/.

Environment overrides (used by tests): AEGIS_CLI (binary), AEGIS_DATA_DIR
(where tunnel.log / vpn.pid live), AEGIS_TIMEOUT (seconds, both budgets),
AEGIS_CURL (curl binary), AEGIS_PKILL (pkill binary), AEGIS_PS (ps binary),
XDG_CACHE_HOME (home.json cache).
"""
import fcntl
import json
import tempfile
import os
import re
import shutil
import subprocess
import sys
import time
import unicodedata
from datetime import datetime
from pathlib import Path

PLUGIN_ID = "io.github.nimbleaininja.aegis"
HERE = Path(__file__).resolve().parent
ANSI = re.compile(r"\x1b\[[0-9;]*m")
CLI_TIMEOUT = 12.0
CONNECT_TIMEOUT = 60.0
HOME_MAX_AGE = 24 * 3600
ERROR_CAP = 160

# TUN: "Connected to MILAN in TUN mode, running on tun0"
# SOCKS: "Connected to ASTANA in SOCKS mode, listening on 127.0.0.1:1080"
STATUS_CONNECTED = re.compile(r"^Connected to (.+?) in (\S+) mode, (running on|listening on) (\S+)")
STATUS_CONNECTING = re.compile(r"^(?:Re)?[Cc]onnecting to (.+?) in (\S+) mode")
ENDPOINT = re.compile(r"Using endpoint: .*?address=([0-9a-fA-F.:\[\]]+?):(\d+)\b.*?ping=(\d+)ms")
VPN_STATE = re.compile(r"VPN_SS_(CONNECTING|CONNECTED|DISCONNECTED)")
LOG_STAMP = "%d.%m.%Y %H:%M:%S.%f"


class CliError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


# ---------------------------------------------------------------- parsers --

def strip_ansi(text):
    return ANSI.sub("", text or "")


def parse_status(text):
    for line in strip_ansi(text).splitlines():
        line = line.strip()
        m = STATUS_CONNECTED.match(line)
        if m:
            mode = m.group(2).lower()
            is_iface = m.group(3) == "running on"
            return {"state": "connected", "location": m.group(1).strip(), "mode": mode,
                    "iface": m.group(4) if is_iface else None, "listen": None if is_iface else m.group(4)}
        m = STATUS_CONNECTING.match(line)
        if m:
            return {"state": "connecting", "location": m.group(1).strip(), "mode": m.group(2).lower(), "iface": None, "listen": None}
        if line.startswith("VPN is disconnected"):
            return {"state": "disconnected", "location": None, "mode": None, "iface": None, "listen": None}
        if "must log in" in line:
            return {"state": "logged_out", "location": None, "mode": None, "iface": None, "listen": None}
    return {"state": "unknown", "location": None, "mode": None, "iface": None, "listen": None}


def _split_virtual(name):
    name = name.strip()
    if name.lower().endswith("(virtual)"):
        return name[: -len("(virtual)")].strip(), True
    return name, False


def parse_locations(text):
    lines = strip_ansi(text).splitlines()
    header = None
    for i, line in enumerate(lines):
        if "ISO" in line and "COUNTRY" in line and "CITY" in line and "PING" in line:
            header = i
            break
    if header is None:
        return []
    h = lines[header]
    cols = [h.index("ISO"), h.index("COUNTRY"), h.index("CITY"), h.index("PING")]
    rows = []
    for line in lines[header + 1:]:
        if not line.strip() or line.lstrip().startswith("You can"):
            continue
        iso = line[cols[0]:cols[1]].strip()
        country = line[cols[1]:cols[2]].strip()
        cli_name = line[cols[2]:cols[3]].strip()
        ping_text = line[cols[3]:].strip()
        if not (len(iso) == 2 and iso.isalpha()):
            continue
        city, virtual = _split_virtual(cli_name)
        ping = int(ping_text) if ping_text.isdigit() else None
        rows.append({"iso": iso, "country": country, "city": city, "cliName": cli_name,
                     "virtual": virtual, "pingMs": ping})
    return rows


def parse_license(text):
    clean = strip_ansi(text)
    out = {"loggedIn": False, "email": "", "plan": "", "devices": None, "validUntil": None}
    m = re.search(r"Logged in as (\S+)", clean)
    if not m:
        return out
    out["loggedIn"] = True
    out["email"] = m.group(1)
    m = re.search(r"using the (\w+) version", clean)
    if m:
        out["plan"] = m.group(1).upper()
    m = re.search(r"Up to (\d+) devices", clean)
    if m:
        out["devices"] = int(m.group(1))
    m = re.search(r"valid until (\d{4}-\d{2}-\d{2})", clean)
    if m:
        out["validUntil"] = m.group(1)
    return out


def parse_exclusions(mode_text, show_text):
    mode = "general"
    m = re.search(r"exclusion mode is (\w+)", strip_ansi(mode_text))
    if m:
        mode = m.group(1).lower()
    domains = []
    for line in strip_ansi(show_text).splitlines()[1:]:
        line = line.strip()
        if line:
            domains.append(line)
    return {"mode": mode, "domains": domains}


def parse_tunnel_tail(text):
    state = None
    endpoint = None
    connected_at = None
    for line in (text or "").splitlines():
        m = VPN_STATE.search(line)
        if m:
            state = m.group(1).lower()
            if state == "connected":
                connected_at = line[:26]
            continue
        m = ENDPOINT.search(line)
        if m:
            endpoint = {"ip": m.group(1).strip("[]"), "port": int(m.group(2)), "pingMs": int(m.group(3))}
    return {"state": state, "endpoint": endpoint, "connectedAt": connected_at}


CONFIG_KEYS = {
    "Mode": "mode",
    "SOCKS port": "socksPort",
    "SOCKS host": "socksHost",
    "SOCKS username": "socksUsername",
    "DNS upstream": "dns",
    "Tunnel routing mode": "tunRouting",
    "Change system DNS": "changeSystemDns",
    "Update channel": "updateChannel",
    "Protocol": "protocol",
    "Post-quantum cryptography": "postQuantum",
    "Show hints": "showHints",
}
CONFIG_DEFAULTS = {"mode": "tun", "socksPort": 1080, "socksHost": "127.0.0.1", "socksUsername": "",
                   "dns": "default", "tunRouting": "auto", "changeSystemDns": False, "updateChannel": "release",
                   "protocol": "auto", "postQuantum": True, "showHints": True}
DEFAULT_VALUE = re.compile(r"^Default\s*\((.*)\)$", re.I)
VERSION = re.compile(r"\bv?(\d+\.\d+\.\d+)\b")


def _as_bool(value):
    return str(value).strip().lower() in ("on", "true", "1", "yes")


def parse_config(text):
    out = dict(CONFIG_DEFAULTS)
    for line in strip_ansi(text).splitlines():
        if ":" not in line:
            continue
        label, _, raw = line.strip().partition(":")
        key = CONFIG_KEYS.get(label.strip())
        if not key:
            continue
        value = raw.strip()
        m = DEFAULT_VALUE.match(value)
        if m:
            if key == "dns":
                value = "default"
            else:
                value = m.group(1).strip()
        if key == "socksPort":
            out[key] = int(value) if value.isdigit() else CONFIG_DEFAULTS[key]
        elif key in ("changeSystemDns", "postQuantum", "showHints"):
            out[key] = _as_bool(value)
        elif key in ("mode", "protocol", "updateChannel", "tunRouting"):
            out[key] = value.lower() or CONFIG_DEFAULTS[key]
        else:
            out[key] = value
    return out


def parse_update(text, version_text):
    """upToDate is True/False only once check-update's own output was
    recognised (either the "latest version" message or a parseable "new
    version" line, see the fixtures); otherwise it is None, meaning the
    check itself failed or produced something this parser doesn't know
    (e.g. no network) — that must never be read as "up to date" just
    because --version (which needs no network) still answered."""
    clean = strip_ansi(text)
    current = None
    m = VERSION.search(strip_ansi(version_text or ""))
    if m:
        current = m.group(1)
    if "latest version" in clean and "is now available" not in clean:
        return {"upToDate": True, "current": current, "latest": None}
    latest = None
    for line in clean.splitlines():
        if "running" in line:
            continue
        m = VERSION.search(line)
        if m:
            latest = m.group(1)
            break
    if latest is not None:
        return {"upToDate": latest == current, "current": current, "latest": latest}
    return {"upToDate": None, "current": current, "latest": None}


# -------------------------------------------------------------- locations --

def _fold(name):
    name, _ = _split_virtual(name or "")
    decomposed = unicodedata.normalize("NFKD", name)
    return "".join(c for c in decomposed if not unicodedata.combining(c)).casefold().strip()


def load_locations(path=None):
    path = Path(path) if path else HERE / "assets" / "locations.json"
    with open(path, encoding="utf-8") as f:
        rows = json.load(f)
    for row in rows:
        row["_key"] = _fold(row["city"])
    return rows


def match_location(locations, name):
    key = _fold(name)
    if not key:
        return None
    for row in locations:
        if row["_key"] == key:
            return row
    return None


# ------------------------------------------------------------ local state --

def data_dir():
    override = os.environ.get("AEGIS_DATA_DIR")
    if override:
        return Path(override)
    base = os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".local" / "share")
    return Path(base) / "adguardvpn-cli"


def read_tunnel_tail(directory, size=65536):
    path = Path(directory) / "tunnel.log"
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            end = f.tell()
            f.seek(max(0, end - size))
            return f.read().decode("utf-8", "replace")
    except OSError:
        return ""


def read_counters(iface_dir):
    try:
        stats = Path(iface_dir) / "statistics"
        rx = int((stats / "rx_bytes").read_text().strip())
        tx = int((stats / "tx_bytes").read_text().strip())
        return rx, tx
    except (OSError, ValueError):
        return 0, 0


def read_since(directory, connected_at=None):
    """Epoch seconds the *current* connection came up.

    The daemon (vpn.pid) stays running across a location switch — it just
    disconnects and reconnects on the same process — so its own elapsed time
    (ps etimes) is the daemon's uptime, not this connection's. tunnel.log's
    last VPN_SS_CONNECTED line is the better source: prefer it, but only
    when it is not older than the daemon itself (a leftover line from a
    previous, already-rotated-out daemon would otherwise understate the
    uptime). With both available, use whichever is more recent
    (max(daemon start, last connect)); with only one, use that one."""
    daemon_start = None
    try:
        pid = int((Path(directory) / "vpn.pid").read_text().strip())
        ps = os.environ.get("AEGIS_PS") or shutil.which("ps") or "ps"
        out = subprocess.run([ps, "-o", "etimes=", "-p", str(pid)], capture_output=True, text=True, timeout=3)
        if out.returncode == 0 and out.stdout.strip().isdigit():
            daemon_start = int(time.time()) - int(out.stdout.strip())
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    log_connected = None
    if connected_at:
        try:
            log_connected = int(datetime.strptime(connected_at, LOG_STAMP).timestamp())
        except ValueError:
            pass
    if log_connected is not None and daemon_start is not None:
        return max(daemon_start, log_connected)
    if log_connected is not None:
        return log_connected
    return daemon_start


# -------------------------------------------------------------------- cli --

def cli_path():
    override = os.environ.get("AEGIS_CLI")
    if override:
        return override
    found = shutil.which("adguardvpn-cli")
    return found or "/opt/adguardvpn_cli/adguardvpn-cli"


def timeout_for(default):
    override = os.environ.get("AEGIS_TIMEOUT")
    if override:
        try:
            return float(override)
        except ValueError:
            pass
    return default


def lock_path():
    override = os.environ.get("AEGIS_LOCK")
    if override:
        return override
    base = os.environ.get("XDG_RUNTIME_DIR") or tempfile.gettempdir()
    return os.path.join(base, "aegis-cli-%d.lock" % os.getuid())


def run_cli(args, timeout=CLI_TIMEOUT):
    binary = cli_path()
    if not (os.path.isfile(binary) and os.access(binary, os.X_OK)):
        raise CliError("cli_missing", "adguardvpn-cli not found")
    # adguardvpn-cli aborts (SIGABRT) when two instances run at once, and more
    # than one helper can be alive during a shell reload, so every CLI call
    # takes a user-wide file lock.
    try:
        lock = open(lock_path(), "a+")
    except OSError:
        lock = None
    try:
        if lock is not None:
            fcntl.flock(lock, fcntl.LOCK_EX)
        p = subprocess.run([binary] + list(args), capture_output=True, text=True,
                           timeout=timeout_for(timeout), env=dict(os.environ, TERM="dumb"))
    except subprocess.TimeoutExpired:
        raise CliError("timeout", "adguardvpn-cli %s timed out" % (args[0] if args else ""))
    except OSError as e:
        raise CliError("cli_missing", "adguardvpn-cli could not start: %s" % e)
    finally:
        if lock is not None:
            try:
                fcntl.flock(lock, fcntl.LOCK_UN)
            except OSError:
                pass
            lock.close()
    return p.returncode, strip_ansi(p.stdout), strip_ansi(p.stderr)


def elide(text):
    text = re.sub(r"\s+", " ", str(text or "")).strip()
    return text if len(text) <= ERROR_CAP else text[: ERROR_CAP - 1] + "…"


def classify_failure(stdout, stderr, fallback="unknown"):
    blob = (stdout or "") + "\n" + (stderr or "")
    if "a password is required" in blob or "terminal is required to read the password" in blob:
        return "sudo_password", "sudo needs a password to start the VPN service"
    if "must log in" in blob or "not logged in" in blob.lower():
        return "logged_out", "Not logged in"
    return fallback, elide(stderr.strip() or stdout.strip() or "adguardvpn-cli failed")


# ------------------------------------------------------------------ verbs --

def verb_snapshot():
    rc, out, err = run_cli(["status"])
    status = parse_status(out)
    if status["state"] == "unknown" and rc != 0:
        code, message = classify_failure(out, err)
        raise CliError(code, message)
    tail = parse_tunnel_tail(read_tunnel_tail(data_dir()))
    result = {"ok": True, "state": status["state"], "location": None, "iso": None,
              "iface": status["iface"], "mode": status.get("mode"), "listen": status.get("listen"),
              "endpoint": None, "sinceEpoch": None, "rx": 0, "tx": 0}
    if status["location"]:
        match = match_location(load_locations(), status["location"])
        result["location"] = match["city"] if match else status["location"].title()
        result["iso"] = match["iso"] if match else None
    if status["state"] == "connected":
        result["endpoint"] = tail["endpoint"]
        result["sinceEpoch"] = read_since(data_dir(), tail["connectedAt"])
        if status["iface"]:
            result["rx"], result["tx"] = read_counters(Path("/sys/class/net") / status["iface"])
    return result


def verb_locations():
    rc, out, err = run_cli(["list-locations"])
    rows = parse_locations(out)
    if not rows:
        code, message = classify_failure(out, err, "parse")
        raise CliError(code, message if code != "parse" else "could not parse list-locations")
    table = load_locations()
    merged = []
    for row in rows:
        match = match_location(table, row["city"])
        row["lat"] = match["lat"] if match else None
        row["lon"] = match["lon"] if match else None
        if match:
            row["city"] = match["city"]
            row["country"] = match["country"] or row["country"]
        merged.append(row)
    return {"ok": True, "locations": merged}


def _state_after():
    rc, out, err = run_cli(["status"])
    return parse_status(out)["state"]


def verb_connect(name):
    if not name:
        raise CliError("unknown", "connect needs a location name")
    rc, out, err = run_cli(["connect", "-l", name, "-y", "--no-progress"], CONNECT_TIMEOUT)
    if rc != 0:
        code, message = classify_failure(out, err)
        raise CliError(code, message)
    return {"ok": True, "state": _state_after()}


def verb_disconnect():
    rc, out, err = run_cli(["disconnect"])
    if rc != 0:
        code, message = classify_failure(out, err)
        raise CliError(code, message)
    return {"ok": True, "state": _state_after()}


def verb_account():
    rc, out, err = run_cli(["license"])
    account = parse_license(out + "\n" + err)
    account["ok"] = True
    return account


def verb_logout():
    rc, out, err = run_cli(["logout"])
    if rc != 0:
        code, message = classify_failure(out, err)
        raise CliError(code, message)
    return {"ok": True, "loggedIn": False}


def _exclusions_show():
    rc1, mode_out, err1 = run_cli(["site-exclusions", "mode"])
    rc2, show_out, err2 = run_cli(["site-exclusions", "show"])
    if rc1 != 0 or rc2 != 0:
        code, message = classify_failure(mode_out + show_out, err1 + err2)
        raise CliError(code, message)
    result = parse_exclusions(mode_out, show_out)
    result["ok"] = True
    return result


def verb_exclusions(args):
    action = args[0] if args else "show"
    if action == "show":
        return _exclusions_show()
    if action == "mode":
        mode = (args[1] if len(args) > 1 else "").lower()
        if mode not in ("general", "selective"):
            raise CliError("unknown", "exclusion mode must be general or selective")
        rc, out, err = run_cli(["site-exclusions", "mode", mode])
    elif action in ("add", "remove"):
        domain = (args[1] if len(args) > 1 else "").strip()
        if not domain or any(ch.isspace() for ch in domain):
            raise CliError("unknown", "exclusions %s needs a domain" % action)
        rc, out, err = run_cli(["site-exclusions", action, domain])
    else:
        raise CliError("unknown", "unknown exclusions action: %s" % action)
    if rc != 0:
        code, message = classify_failure(out, err)
        raise CliError(code, message)
    return _exclusions_show()


def cache_path():
    base = os.environ.get("XDG_CACHE_HOME") or str(Path.home() / ".cache")
    return Path(base) / PLUGIN_ID / "home.json"


def default_gateway():
    try:
        p = subprocess.run(["ip", "-o", "route", "show", "to", "default"], capture_output=True, text=True, timeout=3)
        m = re.search(r"via (\S+) dev (\S+)", p.stdout)
        return (m.group(1) + "@" + m.group(2)) if m else p.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def fetch_home(curl):
    try:
        p = subprocess.run([curl, "-fsS", "--max-time", "4", "https://ipinfo.io/json"],
                           capture_output=True, text=True, timeout=8)
    except (OSError, subprocess.SubprocessError):
        return None
    if p.returncode != 0:
        return None
    try:
        info = json.loads(p.stdout)
        lat, lon = (float(x) for x in str(info.get("loc", "")).split(","))
    except (ValueError, TypeError):
        return None
    return {"lat": lat, "lon": lon, "city": str(info.get("city", "")), "iso": str(info.get("country", ""))}


def _home_public(cached):
    return {k: cached.get(k) for k in ("lat", "lon", "city", "iso")}


def home_lookup(state, cache_file, curl):
    """Return (home_or_None, stale, fetched). Only geolocates while the VPN is
    down, and only when there is no cache, the gateway changed, or it is old."""
    try:
        cached = json.loads(Path(cache_file).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        cached = None
    if state != "disconnected":
        return (_home_public(cached) if cached else None), True, False
    gateway = default_gateway()
    fresh = (cached and cached.get("gateway") == gateway
             and time.time() - float(cached.get("fetchedAt") or 0) < HOME_MAX_AGE)
    if fresh:
        return _home_public(cached), False, False
    fetched = fetch_home(curl)
    if not fetched:
        return (_home_public(cached) if cached else None), True, False
    record = dict(fetched, gateway=gateway, fetchedAt=int(time.time()))
    try:
        Path(cache_file).parent.mkdir(parents=True, exist_ok=True)
        Path(cache_file).write_text(json.dumps(record), encoding="utf-8")
    except OSError:
        pass
    return _home_public(record), False, True


def verb_home():
    rc, out, err = run_cli(["status"])
    state = parse_status(out)["state"]
    curl = os.environ.get("AEGIS_CURL") or shutil.which("curl") or "curl"
    home, stale, fetched = home_lookup(state, cache_path(), curl)
    if home is None and state == "disconnected":
        raise CliError("network", "geolocation lookup failed")
    return {"ok": True, "home": home, "stale": stale}


# ----------------------------------------------------------------- config --

CONFIG_SETTERS = {
    "mode": ("set-mode", ("tun", "socks")),
    "protocol": ("set-protocol", ("auto", "http2", "quic")),
    "postQuantum": ("set-post-quantum", "bool"),
    "changeSystemDns": ("set-change-system-dns", "bool"),
    "dns": ("set-dns", "text"),
    "socksHost": ("set-socks-host", "text"),
    "socksPort": ("set-socks-port", "port"),
    "socksUsername": ("set-socks-username", "text"),
    "socksPassword": ("set-socks-password", "text"),
    "socksAuth": ("clear-socks-auth", ("clear",)),
}
BOOL_WORDS = {"on": "on", "true": "on", "1": "on", "yes": "on", "off": "off", "false": "off", "0": "off", "no": "off"}


def config_command(key, value):
    """Map a settings key + value to the CLI argv, validating first."""
    entry = CONFIG_SETTERS.get(key)
    if not entry:
        raise CliError("unknown", "unknown config key: %s" % key)
    sub, kind = entry
    value = str(value if value is not None else "").strip()
    if kind == "bool":
        word = BOOL_WORDS.get(value.lower())
        if not word:
            raise CliError("unknown", "%s must be on or off" % key)
        return ["config", sub, word]
    if kind == "port":
        if not value.isdigit() or not 1 <= int(value) <= 65535:
            raise CliError("unknown", "%s must be a port number" % key)
        return ["config", sub, value]
    if kind == "text":
        if not value or any(ch.isspace() for ch in value):
            raise CliError("unknown", "%s needs a value" % key)
        return ["config", sub, value]
    if value.lower() not in kind:
        raise CliError("unknown", "%s must be one of %s" % (key, ", ".join(kind)))
    if sub == "clear-socks-auth":
        return ["config", sub]
    return ["config", sub, value.lower()]


def _config_show():
    rc, out, err = run_cli(["config", "show"])
    if rc != 0 and "Mode:" not in out:
        code, message = classify_failure(out, err)
        raise CliError(code, message)
    result = parse_config(out)
    result["ok"] = True
    return result


def verb_config(args):
    action = args[0] if args else "show"
    if action == "show":
        return _config_show()
    if action == "set":
        key = args[1] if len(args) > 1 else ""
        value = " ".join(args[2:]) if len(args) > 2 else ""
        argv = config_command(key, value)
        rc, out, err = run_cli(argv)
        if rc != 0:
            code, message = classify_failure(out, err)
            raise CliError(code, message)
        return _config_show()
    raise CliError("unknown", "unknown config action: %s" % action)


def verb_update_check():
    # check-update exits 17 when already up to date, so the exit code is noise.
    rc, out, err = run_cli(["check-update"])
    rc2, version, _ = run_cli(["--version"])
    result = parse_update(out + "\n" + err, version)
    if result["upToDate"] is None:
        # check-update's own output wasn't recognised (e.g. no network 20s
        # after login) — report the failure rather than guessing up to date;
        # Service.qml must not persist this as a successful check.
        code, message = classify_failure(out, err, "parse")
        raise CliError(code, message if code != "parse" else "could not read update status")
    result["ok"] = True
    return result


PROCESS_NAME = re.compile(r"^[A-Za-z0-9._+-]{1,64}$")


COMM_LEN = 15  # the kernel truncates a process's comm to this many bytes


# Process names a VPN kill switch must never offer or touch: shell
# interpreters, this helper's own interpreter and the `ps` it shells out to,
# init/session/login, the desktop's IPC and audio backbone, the compositor
# and bar shell (whichever binary name it runs under), the VPN CLI itself,
# and privilege escalation. Keep this in sync with PROCS_DENY in Model.js
# (that file points back here) — this list is the one verb_kill actually
# enforces against pkill; Model.js additionally keeps the UI from ever
# offering or accepting these names in the first place.
PROCS_DENY = frozenset([
    "sh", "bash", "zsh", "fish", "dash", "python3", "python", "ps",
    "systemd", "init", "sddm", "gdm", "gdm3", "lightdm",
    "dbus-daemon", "dbus-broker", "pipewire", "wireplumber",
    "Hyprland", "hyprland", "quickshell", "qs", "omarchy-shell",
    "adguardvpn-cli", "sudo", "env",
])
PROCS_DENY_LOWER = frozenset(n.lower() for n in PROCS_DENY)
PROCS_DENY_PREFIXES = ("dbus-broker", "systemd-", "pipewire")
PROCS_CAP = 400


def _is_denied(name):
    # pkill -x matches the exact (truncated) comm case-sensitively, but the
    # deny list itself is compared case-insensitively so e.g. "HYPRLAND" is
    # refused too, not just the exact spellings on the list.
    lower = name.lower()
    return lower in PROCS_DENY_LOWER or lower.startswith(PROCS_DENY_PREFIXES)


def verb_kill(names):
    """Kill listed apps by exact process name via pkill -x. Never touches a
    deny-listed name (PROCS_DENY) even if it slipped in through free text
    (KillSwitchView's field or a hand-edited killApps setting string) —
    Model.js keeps the UI from offering or accepting one, but this is the
    layer that actually calls pkill, so it enforces the rule again."""
    pkill = os.environ.get("AEGIS_PKILL") or shutil.which("pkill") or "pkill"
    killed, missing, rejected, skipped = [], [], [], []
    for name in names:
        if not (name or "").strip():
            continue
        if not PROCESS_NAME.match(name):
            rejected.append(name)
            continue
        if _is_denied(name):
            skipped.append(name)
            continue
        # pkill -x compares against the truncated comm, so a long executable
        # name only matches by its first COMM_LEN characters.
        try:
            p = subprocess.run([pkill, "-x", "--", name[:COMM_LEN]], capture_output=True, text=True, timeout=5)
            (killed if p.returncode == 0 else missing).append(name)
        except (OSError, subprocess.SubprocessError):
            missing.append(name)
    return {"ok": True, "killed": killed, "missing": missing, "rejected": rejected, "skipped": skipped}


def verb_procs():
    """Unique process names owned by the current user, for the kill-switch autosuggest.

    ps gives the kernel comm (truncated to COMM_LEN); the executable's real
    basename from /proc/<pid>/exe is preferred when it is readable, so long
    names such as transmission-gtk are offered in full."""
    ps = os.environ.get("AEGIS_PS") or shutil.which("ps") or "ps"
    proc_root = os.environ.get("AEGIS_PROC") or "/proc"
    try:
        p = subprocess.run([ps, "-u", str(os.getuid()), "-o", "pid=,comm="], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError) as exc:
        raise CliError("unknown", "ps failed: %s" % exc)
    if p.returncode != 0:
        raise CliError("unknown", "ps exited %d" % p.returncode)
    seen = set()
    names = []
    for line in p.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) < 2:
            continue
        pid, comm = parts[0], parts[1].strip()
        name = comm
        try:
            exe = os.path.basename(os.readlink(os.path.join(proc_root, pid, "exe")))
            if exe and exe[:COMM_LEN] == comm[:COMM_LEN]:
                name = exe
        except OSError:
            pass
        if not name or name in seen or _is_denied(name) or not PROCESS_NAME.match(name):
            continue
        seen.add(name)
        names.append(name)
        if len(names) >= PROCS_CAP:
            break
    names.sort(key=lambda n: n.lower())
    return {"ok": True, "procs": names}


# ------------------------------------------------------------------- main --

def dispatch(argv):
    verb = argv[0] if argv else ""
    rest = argv[1:]
    if verb == "snapshot":
        return verb_snapshot()
    if verb == "locations":
        return verb_locations()
    if verb == "connect":
        return verb_connect(" ".join(rest).strip())
    if verb == "disconnect":
        return verb_disconnect()
    if verb == "account":
        return verb_account()
    if verb == "logout":
        return verb_logout()
    if verb == "exclusions":
        return verb_exclusions(rest)
    if verb == "home":
        return verb_home()
    if verb == "config":
        return verb_config(rest)
    if verb == "update-check":
        return verb_update_check()
    if verb == "kill":
        return verb_kill(rest)
    if verb == "procs":
        return verb_procs()
    raise CliError("unknown", "unknown verb: %s" % (verb or "(none)"))


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    try:
        result = dispatch(argv)
    except CliError as e:
        result = {"ok": False, "error": elide(e.message), "code": e.code}
    except Exception as e:  # never let a traceback reach the shell
        result = {"ok": False, "error": elide("%s: %s" % (type(e).__name__, e)), "code": "unknown"}
    sys.stdout.write(json.dumps(result, ensure_ascii=False) + "\n")
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
