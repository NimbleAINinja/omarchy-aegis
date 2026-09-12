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
    python3 agvpn.py home cached          # cached location only; no CLI call, no network, any VPN state
    python3 agvpn.py home forget          # delete the cached location; no CLI call, no network
    python3 agvpn.py config show | set <key> <value>
    python3 agvpn.py config set socksPassword -   # the password is one line on stdin
    python3 agvpn.py update-check
    python3 agvpn.py sudo-check           # would sudo start the VPN service without a password?
    python3 agvpn.py cli-path             # where the binary is; no CLI call, no lock
    python3 agvpn.py kill <name> [name...]

Always exits 0. Success is {"ok": true, ...}; failure is
{"ok": false, "error": "<=160 chars", "code": "<cli_missing|logged_out|sudo_password|timeout|parse|network|unknown>"}.
The CLI has no machine-readable output and always emits ANSI colour, so every
read goes through strip_ansi() and a fixed-width or regex parser tested
against recorded fixtures in tests/fixtures/.

Every queued verb answers within its own overall budget (verb_budget), and
SIGTERM/SIGHUP/SIGINT stop and reap a running adguardvpn-cli before the
helper answers {"ok": false, "code": "timeout"}.

State the helper writes (the CLI lock, home.json, cli-version.json) only ever
lives in a directory this user owns and nobody else can write to:
$XDG_RUNTIME_DIR when it checks out (trusted_runtime_dir), otherwise a
private 0700 directory under the user's own cache dir (private_dir) — never a
shared temp dir. Files in it
are opened without following symlinks and checked to be this user's regular
files; a path that fails the checks is refused, not worked around.

Environment overrides (used by tests): AEGIS_CLI (binary), AEGIS_DATA_DIR
(where tunnel.log / vpn.pid live), AEGIS_TIMEOUT (seconds, both per-call
timeouts; budgets scale with it), AEGIS_BUDGET (seconds, a verb's overall
budget), AEGIS_STOP_GRACE (seconds between SIGTERM and SIGKILL for the CLI
child when stopped), AEGIS_LOCK (lock file, used as given — its directory is
not checked, the file itself still is), AEGIS_CURL (curl binary), AEGIS_PKILL
(pkill binary), AEGIS_PS (ps binary), AEGIS_PROC (the /proc to read process
start times and executables from). Also honoured: XDG_RUNTIME_DIR (CLI lock)
and XDG_CACHE_HOME (home.json and cli-version.json, and the CLI lock when
XDG_RUNTIME_DIR can't be trusted).
"""
import errno
import fcntl
import json
import tempfile
import os
import re
import select
import shutil
import signal
import stat
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
PS_TIMEOUT = 3.0       # read_since's ps fallback
PROCS_TIMEOUT = 5.0    # verb_procs's ps
SUDO_CHECK_TIMEOUT = 5.0  # verb_sudo_check's sudo -l
ROUTE_TIMEOUT = 3.0    # default_gateway's ip route
CURL_TIMEOUT = 8.0     # fetch_home's curl
STDIN_TIMEOUT = 3.0    # read_stdin_secret's wait for the line
SECRET_MAX = 256       # bytes, a secret read from stdin
LOCK_POLL = 0.1
STOP_GRACE = 3.0
HOME_MAX_AGE = 24 * 3600
ERROR_CAP = 160

# TUN: "Connected to MILAN in TUN mode, running on tun0"
# SOCKS: "Connected to ASTANA in SOCKS mode, listening on 127.0.0.1:1080"
STATUS_CONNECTED = re.compile(r"^Connected to (.+?) in (\S+) mode, (running on|listening on) (\S+)")
STATUS_CONNECTING = re.compile(r"^(?:Re)?[Cc]onnecting to (.+?) in (\S+) mode")
ENDPOINT = re.compile(r"Using endpoint: .*?address=([0-9a-fA-F.:\[\]]+?):(\d+)\b.*?ping=(\d+)ms")
VPN_STATE = re.compile(r"VPN_SS_(CONNECTING|CONNECTED|DISCONNECTED)")
# "Exclusions for GENERAL mode:" — site-exclusions show's first line.
EXCL_HEADER = re.compile(r"^Exclusions for (\w+) mode", re.I)
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


def mode_from_show(show_text):
    """The exclusion mode named by `site-exclusions show`'s own header line
    ("Exclusions for SELECTIVE mode:"), or None when it isn't there — only
    then does the mode need its own CLI call (see _exclusions_show)."""
    lines = strip_ansi(show_text).splitlines()
    m = EXCL_HEADER.match(lines[0].strip()) if lines else None
    return m.group(1).lower() if m else None


def parse_exclusions(show_text, mode_text=None):
    """`show`'s header carries the mode, so `mode_text` (the output of
    `site-exclusions mode`) is only consulted when the header is missing."""
    mode = mode_from_show(show_text)
    if mode is None:
        m = re.search(r"exclusion mode is (\w+)", strip_ansi(mode_text or ""))
        mode = m.group(1).lower() if m else "general"
    domains = []
    for line in strip_ansi(show_text).splitlines()[1:]:
        line = line.strip()
        if line:
            domains.append(line)
    return {"mode": mode, "domains": domains}


def parse_tunnel_tail(text):
    """The last state line, the last endpoint line and the last connect stamp
    in the tail — all three are the *last* of their kind, so the scan runs
    backwards and stops as soon as it has them instead of reading the whole
    64 KB. (The last connect stamp can be older than the last state line: a
    disconnect after it leaves connectedAt where it was.)"""
    state = None
    endpoint = None
    connected_at = None
    for line in reversed((text or "").splitlines()):
        m = VPN_STATE.search(line)
        if m:
            if state is None:
                state = m.group(1).lower()
            if connected_at is None and m.group(1).lower() == "connected":
                connected_at = line[:26]
        elif endpoint is None:
            m = ENDPOINT.search(line)
            if m:
                endpoint = {"ip": m.group(1).strip("[]"), "port": int(m.group(2)), "pingMs": int(m.group(3))}
        if state is not None and endpoint is not None and connected_at is not None:
            break
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


def proc_root():
    return os.environ.get("AEGIS_PROC") or "/proc"


def proc_start_epoch(pid):
    """Epoch seconds process `pid` started, straight out of /proc — no fork.

    /proc/<pid>/stat field 22 (starttime) counts clock ticks since boot and
    follows the comm field, which can hold spaces and brackets of its own, so
    the line is split after its last ")"; /proc/uptime turns ticks since boot
    back into an epoch. OSError/ValueError/IndexError (no /proc, a dead pid,
    a line shaped differently) is read_since's cue to fall back to `ps`."""
    with open(os.path.join(proc_root(), str(pid), "stat"), "rb") as f:
        fields = f.read().decode("utf-8", "replace").rsplit(")", 1)[1].split()
    ticks = float(fields[19])  # field 22 counting the pid and comm before it
    with open(os.path.join(proc_root(), "uptime"), "rb") as f:
        uptime = float(f.read().split()[0])
    return int(time.time() - uptime + ticks / os.sysconf("SC_CLK_TCK"))


def ps_start_epoch(pid):
    """Epoch seconds `pid` started per `ps -o etimes=`, or None. The fallback
    for a kernel whose /proc doesn't answer (see proc_start_epoch); AEGIS_PS
    points the tests at their own stand-in."""
    ps = os.environ.get("AEGIS_PS") or shutil.which("ps") or "ps"
    try:
        out = subprocess.run([ps, "-o", "etimes=", "-p", str(pid)], capture_output=True, text=True,
                             timeout=time_left(PS_TIMEOUT))
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode == 0 and out.stdout.strip().isdigit():
        return int(time.time()) - int(out.stdout.strip())
    return None


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
    except (OSError, ValueError):
        pid = None
    if pid is not None:
        try:
            daemon_start = proc_start_epoch(pid)
        except (OSError, ValueError, IndexError):
            daemon_start = ps_start_epoch(pid)  # no /proc to read: fork `ps` after all
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


class UntrustedPath(Exception):
    """A state path that is a symlink, not ours, or not what it should be.
    Deliberately not an OSError, so no `except OSError` that tolerates an
    ordinary filesystem failure can quietly swallow a refusal."""

    def __init__(self, path):
        super().__init__("untrusted path: %s" % path)
        self.path = str(path)


def _owned_by_me(st):
    return st.st_uid == os.getuid()


def cache_dir():
    # A relative XDG_CACHE_HOME would resolve against whatever directory the
    # shell was started in; the XDG spec says to ignore it.
    base = os.environ.get("XDG_CACHE_HOME")
    if not (base and os.path.isabs(base)):
        base = str(Path.home() / ".cache")
    return Path(base) / PLUGIN_ID


def private_dir(path):
    """Create `path` as a directory only this user can enter (0700), or
    verify and tighten an existing one, and return it as a string.

    Only the last component is vetted: it must be a real directory, not a
    symlink, owned by this uid, else UntrustedPath. Its parents belong to the
    user (a symlinked ~/.cache is their business) and are just created as
    needed. The checks and the chmod go through one O_NOFOLLOW descriptor,
    so a symlink swapped in after mkdir is refused rather than followed.
    Anything else that goes wrong (read-only home, EACCES) is an OSError."""
    path = os.fspath(Path(path))  # Path drops a trailing "/", which would make open() follow a symlink
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, 0o700, exist_ok=True)
    try:
        os.mkdir(path, 0o700)
    except FileExistsError:
        pass  # checked below like any other directory
    try:
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError as e:
        if e.errno in (errno.ELOOP, errno.ENOTDIR):  # a symlink, or not a directory at all
            raise UntrustedPath(path)
        raise
    try:
        st = os.fstat(fd)
        if not _owned_by_me(st):
            raise UntrustedPath(path)
        if stat.S_IMODE(st.st_mode) != 0o700:
            os.fchmod(fd, 0o700)
    finally:
        os.close(fd)
    return path


def trusted_runtime_dir():
    """$XDG_RUNTIME_DIR, but only if it is an absolute path to a real
    directory (lstat: not a symlink) owned by this uid that neither group nor
    others can write to; None otherwise. It is not ours to create or chmod,
    so anything less is simply not used."""
    base = (os.environ.get("XDG_RUNTIME_DIR") or "").rstrip("/")  # "dir/" would make lstat follow a symlink
    if not os.path.isabs(base):
        return None
    try:
        st = os.lstat(base)
    except OSError:
        return None
    if not stat.S_ISDIR(st.st_mode) or not _owned_by_me(st) or st.st_mode & 0o022:
        return None
    return base


# -------------------------------------------------------------------- cli --

def cli_path():
    override = os.environ.get("AEGIS_CLI")
    if override:
        return override
    found = shutil.which("adguardvpn-cli")
    return found or "/opt/adguardvpn_cli/adguardvpn-cli"


def env_seconds(name, default):
    override = os.environ.get(name)
    if override:
        try:
            return float(override)
        except ValueError:
            pass
    return default


def timeout_for(default):
    return env_seconds("AEGIS_TIMEOUT", default)


def lock_path():
    """Where the user-wide CLI lock lives: AEGIS_LOCK (tests), else
    $XDG_RUNTIME_DIR when trusted_runtime_dir() accepts it, else a private
    directory under the user's cache dir. Never a shared temp dir: anyone
    can pre-create a file there and hold a lock on it (every CLI call then
    times out waiting) or plant a symlink for us to create a file through.
    Raises UntrustedPath/OSError when the fallback directory can't be used."""
    override = os.environ.get("AEGIS_LOCK")
    if override:
        return override
    runtime = trusted_runtime_dir()
    if runtime:
        return os.path.join(runtime, "aegis-cli-%d.lock" % os.getuid())
    return os.path.join(private_dir(cache_dir()), "cli.lock")


def open_lock(path):
    """Open (creating 0600 if needed) the lock file and return its fd.

    O_NOFOLLOW so a symlink at `path` is refused instead of creating or
    locking a file wherever it points; the fd must then be a regular file
    owned by this uid (a FIFO, directory or someone else's file is refused),
    and is narrowed to 0600 if it is wider (older versions left it 0644).
    Any failure is a CliError: the CLI never runs unlocked because the lock
    path was untrusted or unusable."""
    try:
        fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    except OSError as e:
        if e.errno == errno.ELOOP:
            raise CliError("unknown", "refusing to use untrusted lock path %s" % path)
        raise CliError("unknown", "cannot open lock file %s: %s" % (path, e.strerror or e))
    try:
        st = os.fstat(fd)
        trusted = stat.S_ISREG(st.st_mode) and _owned_by_me(st)
        if trusted and stat.S_IMODE(st.st_mode) & ~0o600:
            os.fchmod(fd, 0o600)
    except OSError:
        trusted = False
    if not trusted:
        os.close(fd)
        raise CliError("unknown", "refusing to use untrusted lock path %s" % path)
    return fd


# ---------------------------------------------------------------- budgets --

def verb_budgets():
    """Overall wall-clock budget, in seconds, for one helper run of each
    queued verb: the timeout of every sub-call on its longest path plus one
    ordinary CLI call's worth (LOCK_WAIT = CLI_TIMEOUT) for queueing behind
    another adguardvpn-cli — a helper left over from a shell reload, or its
    orphaned CLI. main() turns it into a deadline that every lock wait and
    sub-call timeout is clipped to (time_left), so the helper answers within
    it. Model.js HELPER_BUDGET_SEC copies these numbers for Service.qml's
    jobWatchdog, which adds slack on top; tests/model.test.js checks the
    copy against this function, so change both together. kill is not
    listed: it is not a queued job, and each pkill must get its chance."""
    cli = timeout_for(CLI_TIMEOUT)
    lock_wait = cli
    # The daemon's age comes from /proc, so a snapshot is one CLI call: the
    # `ps` fallback only runs when /proc has no answer, and time_left clips
    # it to whatever is left of the budget anyway.
    snapshot = cli                                        # status
    calls = {
        "snapshot": snapshot,
        "locations": cli,
        "connect": timeout_for(CONNECT_TIMEOUT) + snapshot,  # connect, then the whole snapshot
        "disconnect": cli + snapshot,                     # disconnect, then the whole snapshot
        "account": cli,
        "logout": cli,
        "exclusions": 3 * cli,                            # mode/add/remove, then show (+ mode if it has no header)
        "home": cli + ROUTE_TIMEOUT + CURL_TIMEOUT,       # status, ip route, curl
        "config": STDIN_TIMEOUT + 2 * cli,                # stdin (socksPassword), set, then show
        "update-check": 2 * cli,                          # check-update, --version (cached per binary)
        "procs": PROCS_TIMEOUT,
        "sudo-check": SUDO_CHECK_TIMEOUT,
        "cli-path": 0,  # a which() and a stat; nothing to wait for but the lock
    }
    return {verb: lock_wait + seconds for verb, seconds in calls.items()}


def verb_budget(verb):
    """The verb's budget in seconds (AEGIS_BUDGET overrides it), or None."""
    budget = verb_budgets().get(verb)
    return None if budget is None else env_seconds("AEGIS_BUDGET", budget)


_deadline = None  # time.monotonic() by which the running verb must answer; None = no budget


def time_left(cap=float("inf")):
    """`cap` seconds, clipped to what is left of the running verb's budget."""
    if _deadline is None:
        return cap
    return max(0.0, min(cap, _deadline - time.monotonic()))


# ----------------------------------------------------------- cli lifetime --

class Stopped(BaseException):
    """Raised by the stop-signal handler. A BaseException so no `except
    Exception`/`except OSError` on the way up swallows it; run_cli stops
    and reaps its CLI child on the way through, main() answers timeout."""


STOP_SIGNALS = (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)


def _on_stop(signum, frame):
    # One stop is enough: ignore repeats so they can't interrupt the cleanup.
    for sig in STOP_SIGNALS:
        signal.signal(sig, signal.SIG_IGN)
    raise Stopped()


def _lock_free(fd):
    """Whether no adguardvpn-cli holds the lock right now (probe only)."""
    try:
        fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except (BlockingIOError, PermissionError):
        return False
    fcntl.lockf(fd, fcntl.LOCK_UN)
    return True


def _take_lock_in_child(fd):
    def take():
        # Runs in the forked child just before exec: undo the parent's
        # signal block (the mask would survive exec and leave the CLI deaf
        # to SIGTERM), then take the lock as the CLI process itself. Losing
        # the race to another helper fails the spawn (SubprocessError); a
        # filesystem without record locks just runs unlocked.
        signal.pthread_sigmask(signal.SIG_UNBLOCK, STOP_SIGNALS)
        try:
            fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except (BlockingIOError, PermissionError):
            raise
        except OSError:
            pass
    return take


def _stdin_pipe(data):
    """The read end of a pipe that already holds `data`, its write end
    closed: whoever gets it as stdin reads `data`, then EOF. Filled before
    the spawn, so the CLI can never block us or be sent EPIPE, and one short
    line is far below PIPE_BUF, so the write is never partial."""
    r, w = os.pipe()
    try:
        view = memoryview(data)
        while view:
            view = view[os.write(w, view):]
    except BaseException:
        os.close(r)
        raise
    finally:
        os.close(w)
    return r


def _spawn_cli(argv, name, out, err, lock, started, stdin_data=None):
    """Start the CLI once the lock is free, appending its Popen to `started`
    before stop signals are let through again, so a SIGTERM that lands
    mid-spawn still finds (and stops) the child. Waits no longer than what
    is left of the budget (LOCK_WAIT when there is none). `stdin_data`
    (bytes) is what the CLI reads on stdin; None gives it /dev/null."""
    give_up = time.monotonic() + (time_left() if _deadline is not None else timeout_for(CLI_TIMEOUT))
    while True:
        # Checked before spawning too: never start a CLI call (a connect,
        # say) there is no time left to wait for.
        if time.monotonic() >= give_up:
            raise CliError("timeout", "adguardvpn-cli %s timed out waiting for its turn" % name)
        if lock is None or _lock_free(lock):
            blocked = signal.pthread_sigmask(signal.SIG_BLOCK, STOP_SIGNALS)
            stdin = None
            try:
                # A fresh pipe for every attempt: a spawn that lost the lock
                # race had its copy closed below along with ours.
                if stdin_data is not None:
                    stdin = _stdin_pipe(stdin_data)
                started.append(subprocess.Popen(
                    argv, stdin=subprocess.DEVNULL if stdin is None else stdin, stdout=out, stderr=err,
                    env=dict(os.environ, TERM="dumb"),
                    pass_fds=(lock,) if lock is not None else (),
                    preexec_fn=_take_lock_in_child(lock) if lock is not None else None))
                return
            except subprocess.SubprocessError:
                pass  # another helper's CLI took the lock between probe and exec
            finally:
                # The child has the pipe as its fd 0 by now (close_fds drops
                # the original number there); our end is no longer needed.
                if stdin is not None:
                    os.close(stdin)
                signal.pthread_sigmask(signal.SIG_SETMASK, blocked)
        time.sleep(LOCK_POLL)


def _stop_child(p, grace):
    """SIGTERM p, SIGKILL it after `grace` seconds, and reap it — only then
    is its lock gone. Only p itself: a process-group kill could take the
    VPN daemon the CLI starts with it."""
    if p.poll() is not None:
        return
    if grace > 0:
        p.terminate()
        try:
            p.wait(timeout=grace)
            return
        except subprocess.TimeoutExpired:
            pass
    p.kill()
    p.wait()


def _captured(f):
    # What text=True used to give: decoded, universal newlines.
    f.seek(0)
    text = f.read().decode("utf-8", "replace")
    return strip_ansi(text.replace("\r\n", "\n").replace("\r", "\n"))


def run_cli(args, timeout=CLI_TIMEOUT, stdin_data=None):
    # stdin_data: bytes for the CLI's stdin — a secret that must stay out of
    # its argv (see _config_set_secret). Every other call gets /dev/null.
    binary = cli_path()
    if not (os.path.isfile(binary) and os.access(binary, os.X_OK)):
        raise CliError("cli_missing", "adguardvpn-cli not found")
    name = args[0] if args else ""
    # adguardvpn-cli aborts (SIGABRT) when two instances run at once, and more
    # than one helper can be alive during a shell reload, so every CLI call
    # takes a user-wide lock. It is a POSIX record lock owned by the
    # adguardvpn-cli process itself (taken between fork and exec): it
    # survives exec, goes away exactly when that process exits, and is not
    # inherited by anything the CLI forks (unlike a flock on a passed fd,
    # which a daemon keeping the fd would hold forever). A flock held here
    # died with the helper, so a watchdog kill or the SIGKILL Quickshell
    # sends on reload let the next job's CLI overlap the orphaned one.
    try:
        path = lock_path()
    except UntrustedPath as e:
        raise CliError("unknown", "refusing to use untrusted lock path %s" % e.path)
    except OSError as e:
        raise CliError("unknown", "cannot create lock directory: %s" % e)
    lock = open_lock(path)  # a CliError when the path can't be trusted: never run unlocked for that
    try:
        _lock_free(lock)
    except OSError:
        # The one case that runs unlocked: a filesystem without POSIX record
        # locks (lockf fails with something other than "held by another
        # process", which _lock_free already answers as False).
        os.close(lock)
        lock = None
    # Output goes to unlinked temp files, never pipes: an orphaned CLI
    # writing to a dead pipe aborts ("cannot write to file: Broken pipe",
    # adguardvpn-cli 1.7.12), which is how a reload mid-connect crashed it.
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        started = []
        try:
            _spawn_cli([binary] + list(args), name, out, err, lock, started, stdin_data)
            rc = started[0].wait(timeout=time_left(timeout_for(timeout)))
        except subprocess.TimeoutExpired:
            _stop_child(started[0], 0)
            raise CliError("timeout", "adguardvpn-cli %s timed out" % name)
        except OSError as e:
            raise CliError("cli_missing", "adguardvpn-cli could not start: %s" % e)
        except Stopped:
            if started:
                _stop_child(started[0], env_seconds("AEGIS_STOP_GRACE", STOP_GRACE))
            raise
        finally:
            if lock is not None:
                os.close(lock)
        return rc, _captured(out), _captured(err)


def elide(text):
    text = re.sub(r"\s+", " ", str(text or "")).strip()
    return text if len(text) <= ERROR_CAP else text[: ERROR_CAP - 1] + "…"


def classify_failure(stdout, stderr, fallback="unknown"):
    blob = (stdout or "") + "\n" + (stderr or "")
    if "a password is required" in blob or "terminal is required to read the password" in blob:
        return "sudo_password", "sudo needs a password to start the VPN service"
    # The CLI says this three ways: "you must log in" (connect), "You are
    # not logged in" (status), and "Please log in to <do the thing>"
    # (list-locations, license). All three carry the same hint line, which
    # is the one marker every phrasing shares.
    low = blob.lower()
    if ("must log in" in low or "not logged in" in low or "please log in" in low
            or "you can log in by running" in low):
        return "logged_out", "Not logged in"
    return fallback, elide(stderr.strip() or stdout.strip() or "adguardvpn-cli failed")


# ------------------------------------------------------------------ verbs --

def blank_snapshot(state):
    """Every field a snapshot answers with, for `state` and nothing else
    known. connect/disconnect answer in this shape too (see _snapshot_after),
    so Service.qml can apply any of them the same way."""
    return {"ok": True, "state": state, "location": None, "iso": None,
            "iface": None, "mode": None, "listen": None,
            "endpoint": None, "sinceEpoch": None, "rx": 0, "tx": 0}


def verb_snapshot():
    rc, out, err = run_cli(["status"])
    status = parse_status(out)
    if status["state"] == "unknown" and rc != 0:
        code, message = classify_failure(out, err)
        raise CliError(code, message)
    result = blank_snapshot(status["state"])
    result["iface"] = status["iface"]
    result["mode"] = status.get("mode")
    result["listen"] = status.get("listen")
    if status["location"]:
        match = match_location(load_locations(), status["location"])
        result["location"] = match["city"] if match else status["location"].title()
        result["iso"] = match["iso"] if match else None
    if status["state"] == "connected":
        # Only a live tunnel has an endpoint and an uptime to report, so the
        # log tail is read and parsed only then.
        tail = parse_tunnel_tail(read_tunnel_tail(data_dir()))
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


def _snapshot_after():
    """The whole snapshot after a connect or disconnect, for the price of the
    `status` call those verbs already made anyway: the panel gets the new
    location, endpoint, uptime and counters straight from the job it asked
    for, instead of blanking the hero until the next poll lands.

    A `status` that fails here must not turn a successful connect into an
    error — the VPN did what it was told — so it only costs the details."""
    try:
        return verb_snapshot()
    except CliError:
        return blank_snapshot("unknown")


def verb_connect(name):
    if not name:
        raise CliError("unknown", "connect needs a location name")
    # A name starting with "-" would be parsed by adguardvpn-cli's own option
    # parser (CLI11) as an option rather than -l's value; it is our own argv
    # word (no shell involved), but that still isn't a location name.
    if name.startswith("-"):
        raise CliError("unknown", "connect name must not start with -")
    rc, out, err = run_cli(["connect", "-l", name, "-y", "--no-progress"], CONNECT_TIMEOUT)
    if rc != 0:
        code, message = classify_failure(out, err)
        raise CliError(code, message)
    return _snapshot_after()


def verb_disconnect():
    rc, out, err = run_cli(["disconnect"])
    if rc != 0:
        code, message = classify_failure(out, err)
        raise CliError(code, message)
    return _snapshot_after()


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
    # One call: `show` names the mode in its header line, so the separate
    # `site-exclusions mode` call is only made when that header is missing
    # (a CLI that doesn't print it).
    rc, show_out, err = run_cli(["site-exclusions", "show"])
    if rc != 0:
        code, message = classify_failure(show_out, err)
        raise CliError(code, message)
    mode_out = ""
    if mode_from_show(show_out) is None:
        rc2, mode_out, err2 = run_cli(["site-exclusions", "mode"])
        if rc2 != 0:
            code, message = classify_failure(mode_out, err2)
            raise CliError(code, message)
    result = parse_exclusions(show_out, mode_out)
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
        # A leading "-" would reach adguardvpn-cli as an option word, not a
        # domain (see config_command's "text" check for the same rule).
        if not domain or any(ch.isspace() for ch in domain) or domain.startswith("-"):
            raise CliError("unknown", "exclusions %s needs a domain" % action)
        rc, out, err = run_cli(["site-exclusions", action, domain])
    else:
        raise CliError("unknown", "unknown exclusions action: %s" % action)
    if rc != 0:
        code, message = classify_failure(out, err)
        raise CliError(code, message)
    return _exclusions_show()


def cache_path():
    return cache_dir() / "home.json"


def read_private_json(path):
    """The JSON object in `path`, or None unless it is this user's regular
    file. O_NOFOLLOW: a symlink planted as home.json is not read through;
    O_NONBLOCK: a FIFO planted there can't hang the helper (regular files
    ignore the flag). A file that passes those checks but is wider than 0600
    (existing installs can have a 0644 home.json from before the privacy fix
    — it only got narrowed on the next fetch) is tightened right here, via
    the same fd, so a read alone fixes it instead of waiting on a write."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    except OSError:
        return None
    with os.fdopen(fd, "rb") as f:
        try:
            st = os.fstat(f.fileno())
            if not (stat.S_ISREG(st.st_mode) and _owned_by_me(st)):
                return None
            if stat.S_IMODE(st.st_mode) & ~0o600:
                os.fchmod(f.fileno(), 0o600)
            value = json.loads(f.read().decode("utf-8"))
        except (OSError, ValueError):
            return None
    return value if isinstance(value, dict) else None


def write_private_json(path, value):
    """Atomically replace `path` with `value` as a 0600 file; True on success.

    The new content goes to a fresh temp file beside it, created O_EXCL |
    O_NOFOLLOW with mode 0600 (so it is never readable by anyone else, even
    for a moment, and never opened through a symlink), then renamed over
    `path` — rename replaces a symlink at `path` rather than following it,
    and readers never see a half-written file. The temp file is removed on
    any failure. Failures are the caller's to ignore; nothing is raised."""
    path = Path(path)
    tmp = path.with_name(".%s.%s.tmp" % (path.name, os.urandom(6).hex()))
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    except OSError:
        return False
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(json.dumps(value).encode("utf-8"))
        os.replace(tmp, path)
        return True
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return False


def default_gateway():
    try:
        p = subprocess.run(["ip", "-o", "route", "show", "to", "default"], capture_output=True, text=True,
                           timeout=time_left(ROUTE_TIMEOUT))
        m = re.search(r"via (\S+) dev (\S+)", p.stdout)
        return (m.group(1) + "@" + m.group(2)) if m else p.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def fetch_home(curl):
    try:
        p = subprocess.run([curl, "-fsS", "--max-time", "4", "https://ipinfo.io/json"],
                           capture_output=True, text=True, timeout=time_left(CURL_TIMEOUT))
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
    down, and only when there is no cache, the gateway changed, or it is old.

    home.json holds the user's real, non-VPN position and LAN gateway, so its
    directory goes through private_dir (created or tightened to 0700) before
    it is read, and it is written 0600 (write_private_json). A directory that
    fails those checks counts as no cache and is never written to; the
    lookup's answer stands either way, as it did when a write just failed."""
    cache_file = Path(cache_file)
    try:
        private_dir(cache_file.parent)
        usable = True
    except (UntrustedPath, OSError):
        usable = False
    cached = read_private_json(cache_file) if usable else None
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
    if usable:
        write_private_json(cache_file, record)  # a failed write only costs the next lookup
    return _home_public(record), False, True


def verb_home(args):
    if args and args[0] == "forget":
        return verb_home_forget()
    if args and args[0] == "cached":
        return verb_home_cached()
    rc, out, err = run_cli(["status"])
    state = parse_status(out)["state"]
    curl = os.environ.get("AEGIS_CURL") or shutil.which("curl") or "curl"
    home, stale, fetched = home_lookup(state, cache_path(), curl)
    if home is None and state == "disconnected":
        raise CliError("network", "geolocation lookup failed")
    return {"ok": True, "home": home, "stale": stale}


def verb_home_cached():
    """The cached location, straight off disk: no adguardvpn-cli call, no
    curl, and no dependence on VPN state at all — reading the cache reveals
    nothing (it never fetches), only a real lookup (plain `home`, itself
    gated by Service.qml's Model.mayLocateHome) does that. Lets the panel
    show a last-known location immediately, e.g. right after a shell restart
    while still connected, instead of waiting for the tunnel to go down
    before `home` is even allowed to run.

    `stale` is always True: this never proves the cache is still fresh (that
    needs the current default gateway, which `home` alone checks), so
    Service.applyHome keeps trying a real lookup once one is allowed."""
    cache_file = cache_path()
    try:
        private_dir(cache_file.parent)
        usable = True
    except (UntrustedPath, OSError):
        usable = False
    cached = read_private_json(cache_file) if usable else None
    return {"ok": True, "home": _home_public(cached) if cached else None, "stale": True}


def verb_home_forget():
    """Delete the cached home location: no CLI call, no network. ok: True
    whether or not a file was there to delete — there's nothing left to
    forget either way. `os.unlink` acts on the directory entry itself, never
    the file it points to, so a symlink planted as home.json is removed as
    a link and its target is left alone, the same guarantee
    write_private_json's replace-by-rename gives a real fetch."""
    try:
        os.unlink(cache_path())
    except FileNotFoundError:
        pass
    except OSError as e:
        raise CliError("unknown", "could not delete cached location: %s" % (e.strerror or e))
    return {"ok": True}


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
    # "stdin": a secret, read from our stdin and handed to the CLI on its
    # stdin (see _config_set_secret). Model.js CONFIG_STDIN_KEYS mirrors these.
    "socksPassword": ("set-socks-password", "stdin"),
    "socksAuth": ("clear-socks-auth", ("clear",)),
}
NO_TTY = "No TTY for user input"
BOOL_WORDS = {"on": "on", "true": "on", "1": "on", "yes": "on", "off": "off", "false": "off", "0": "off", "no": "off"}


def config_command(key, value):
    """Map a settings key + value to the CLI argv, validating first."""
    entry = CONFIG_SETTERS.get(key)
    if not entry:
        raise CliError("unknown", "unknown config key: %s" % key)
    sub, kind = entry
    value = str(value if value is not None else "").strip()
    if kind == "stdin":
        # Never taken from argv, where every local user can read it: a
        # caller still passing the value itself is refused rather than
        # leaking it on to the CLI's own command line. The message must not
        # echo what was given.
        if value != "-":
            raise CliError("unknown", "%s is read from stdin: pass - as the value" % key)
        return ["config", sub]
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
        # A value starting with "-" would reach adguardvpn-cli as an option
        # word (CLI11), not this setting's value — checked before the empty/
        # whitespace rule so the message names the actual problem. Never
        # applied to socksPassword: that key is "stdin", not "text", because
        # the value never goes on argv at all (see _config_set_secret), so a
        # password starting with "-" is fine.
        if value.startswith("-"):
            raise CliError("unknown", "%s must not start with -" % key)
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


def read_stdin_secret(name, fd=0):
    """One line from stdin — a secret that must not travel in argv — with
    only its trailing newline stripped.

    Stops at the first newline rather than waiting for EOF, and waits no
    longer than STDIN_TIMEOUT (clipped to the budget), so a caller that
    never closes its end can't hang the helper. Refused (CliError, never
    echoing the input): nothing at all, more than SECRET_MAX bytes, anything
    after the newline, invalid UTF-8, and whitespace or other unprintable
    characters (the same no-whitespace rule as the "text" config values)."""
    give_up = time.monotonic() + time_left(STDIN_TIMEOUT)
    data = b""
    try:
        while b"\n" not in data and len(data) <= SECRET_MAX:
            wait = give_up - time.monotonic()
            if wait <= 0:
                raise CliError("timeout", "%s did not arrive on stdin" % name)
            if not select.select([fd], [], [], wait)[0]:
                continue
            chunk = os.read(fd, SECRET_MAX + 2 - len(data))
            if not chunk:
                break  # EOF: a last line without its newline still counts
            data += chunk
    except OSError as e:
        raise CliError("unknown", "cannot read %s from stdin: %s" % (name, e.strerror or type(e).__name__))
    line, _, rest = data.partition(b"\n")
    if len(line) > SECRET_MAX:
        raise CliError("unknown", "%s is longer than %d bytes" % (name, SECRET_MAX))
    if rest:
        raise CliError("unknown", "%s must be a single line" % name)
    try:
        value = line.decode("utf-8")
    except UnicodeDecodeError:
        raise CliError("unknown", "%s is not valid UTF-8" % name)
    if not value:
        raise CliError("unknown", "%s needs a value" % name)
    if any(ch.isspace() or not ch.isprintable() for ch in value):
        raise CliError("unknown", "%s must not contain spaces or control characters" % name)
    return value


def _config_set_secret(key, argv):
    """Set a "stdin" config key: the value comes from our stdin and goes to
    the CLI on its stdin, with no positional — adguardvpn-cli then reads it
    from there instead of prompting. Errors are fixed strings, never the
    CLI's own output, which could repeat what it was given."""
    secret = read_stdin_secret(key)
    rc, out, err = run_cli(argv, stdin_data=(secret + "\n").encode("utf-8"))
    if NO_TTY in out or NO_TTY in err:
        # It found nothing on stdin, tried to prompt, kept the old value and
        # exited 16 — a failure even if a future version exits 0.
        raise CliError("unknown", "adguardvpn-cli did not read %s from stdin" % key)
    if rc != 0:
        code, message = classify_failure(out, err)
        if code == "unknown":
            message = "adguardvpn-cli could not set %s (exit %d)" % (key, rc)
        raise CliError(code, message)
    return _config_show()


def verb_config(args):
    action = args[0] if args else "show"
    if action == "show":
        return _config_show()
    if action == "set":
        key = args[1] if len(args) > 1 else ""
        value = " ".join(args[2:]) if len(args) > 2 else ""
        argv = config_command(key, value)
        if CONFIG_SETTERS[key][1] == "stdin":
            return _config_set_secret(key, argv)
        rc, out, err = run_cli(argv)
        if rc != 0:
            code, message = classify_failure(out, err)
            raise CliError(code, message)
        return _config_show()
    raise CliError("unknown", "unknown config action: %s" % action)


def version_cache_path():
    return cache_dir() / "cli-version.json"


def cli_version():
    """`adguardvpn-cli --version`, remembered under cache_dir() and keyed on
    the binary's (mtime, size): the version can only change when the binary
    does, so a CLI that hasn't been updated costs no second call on every
    update check. A cache that can't be read or written just means the call
    is made, as it always was."""
    try:
        st = os.stat(cli_path())
        key = [st.st_mtime_ns, st.st_size]
    except OSError:
        key = None
    if key is not None:
        cached = read_private_json(version_cache_path())
        if cached and cached.get("key") == key and isinstance(cached.get("version"), str):
            return cached["version"]
    rc, version, _ = run_cli(["--version"])
    if key is not None:
        try:
            private_dir(cache_dir())
            write_private_json(version_cache_path(), {"key": key, "version": version})
        except (UntrustedPath, OSError):
            pass  # a cache we may not write only costs the next check a call
    return version


def verb_update_check():
    # check-update exits 17 when already up to date, so the exit code is noise.
    rc, out, err = run_cli(["check-update"])
    version = cli_version()
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
# and bar shell (whichever binary name it runs under), idle/lock/session
# plumbing (killing hyprlock on a VPN drop would UNLOCK the session instead
# of protecting it), the notification daemon the kill switch's own alert
# depends on (see notify() in Service.qml), the app launcher, the VPN CLI
# itself, and privilege escalation. Keep this in sync with PROCS_DENY in
# Model.js (that file points back here) — this list is the one verb_kill
# actually enforces against pkill; Model.js additionally keeps the UI from
# ever offering or accepting these names in the first place.
PROCS_DENY = frozenset([
    "sh", "bash", "zsh", "fish", "dash", "python3", "python", "ps",
    "systemd", "init", "sddm", "gdm", "gdm3", "lightdm", "login", "agetty",
    "dbus-daemon", "dbus-broker", "pipewire", "wireplumber",
    "Hyprland", "hyprland", "quickshell", "qs", "omarchy-shell",
    "hyprlock", "hypridle", "uwsm", "Xwayland",
    "polkitd", "hyprpolkitagent", "gnome-keyring-daemon", "ssh-agent", "gpg-agent",
    "mako", "swayosd-server", "walker", "elephant",
    "adguardvpn-cli", "sudo", "env",
])
PROCS_DENY_LOWER = frozenset(n.lower() for n in PROCS_DENY)
PROCS_DENY_PREFIXES = ("dbus-broker", "systemd-", "pipewire", "polkit", "xdg-desktop")
# Every deny-listed name too long for the kernel's comm field, truncated the
# same way `ps`/`pkill -x` would see it — see _is_denied.
PROCS_DENY_TRUNCATED = frozenset(n.lower()[:COMM_LEN] for n in PROCS_DENY if len(n) > COMM_LEN)
PROCS_CAP = 400


def _is_denied(name):
    # pkill -x matches the exact (truncated) comm case-sensitively, but the
    # deny list itself is compared case-insensitively so e.g. "HYPRLAND" is
    # refused too, not just the exact spellings on the list.
    lower = name.lower()
    if lower in PROCS_DENY_LOWER or lower.startswith(PROCS_DENY_PREFIXES):
        return True
    # `ps` and `pkill -x` only ever see a process's comm truncated to
    # COMM_LEN bytes, so a name that IS that truncation of a longer denied
    # name (e.g. "gnome-keyring-d" for "gnome-keyring-daemon") must be
    # refused too — pkill -x on it would still hit the real process.
    return len(lower) == COMM_LEN and lower in PROCS_DENY_TRUNCATED


def verb_kill(names):
    """Kill listed apps by exact process name via pkill -u <uid> -x, scoped to
    this user's own processes (uid = os.getuid(), the same id verb_procs's
    `ps -u` filters on). Without -u, pkill -x matches that name for every
    user on the system: a same-named process another user owns would either
    get killed (if this user's sudo/setuid lets pkill reach it) or, more
    likely, make pkill fail with EPERM on that other match even though this
    user's own process (if any) was found and signalled fine — turning a
    plain "missing" into a spurious failure. Never touches a deny-listed name
    (PROCS_DENY) even if it slipped in through free text (KillSwitchView's
    field or a hand-edited killApps setting string) — Model.js keeps the UI
    from offering or accepting one, but this is the layer that actually calls
    pkill, so it enforces the rule again."""
    pkill = os.environ.get("AEGIS_PKILL") or shutil.which("pkill") or "pkill"
    uid = str(os.getuid())
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
            p = subprocess.run([pkill, "-u", uid, "-x", "--", name[:COMM_LEN]], capture_output=True, text=True,
                               timeout=5)
            (killed if p.returncode == 0 else missing).append(name)
        except (OSError, subprocess.SubprocessError):
            missing.append(name)
    return {"ok": True, "killed": killed, "missing": missing, "rejected": rejected, "skipped": skipped}


def sudo_probe_argv():
    """The argv adguardvpn-cli hands to `sudo -b` to start its VPN service
    (tests/sudoers.test.sh pins the same shape against the README rule),
    filled in for this user and session: the home and data directories, the
    display and session bus the CLI exports, and its own resolved path."""
    home = os.environ.get("HOME") or os.path.expanduser("~")
    data = os.environ.get("XDG_DATA_HOME") or os.path.join(home, ".local", "share")
    display = os.environ.get("DISPLAY") or ":0"
    bus = os.environ.get("DBUS_SESSION_BUS_ADDRESS") or "unix:path=/run/user/%d/bus" % os.getuid()
    return ["/usr/bin/env", "HOME=" + home, "XDG_DATA_HOME=" + data, "DISPLAY=" + display,
            "DBUS_SESSION_BUS_ADDRESS=" + bus, os.path.realpath(cli_path()),
            "connect", "--no-fork", "-l", "Probe", "--log-to-file", "--wait-for-parent",
            "--ppid-file", os.path.join(data, "adguardvpn-cli", "vpn.pid")]


def sudo_nopasswd_for(listing, binary):
    """Whether a `sudo -l` listing carries a NOPASSWD entry for `binary`.
    sudo prints one entry per line, so each line is read on its own: a
    NOPASSWD line naming the CLI is the rule aegis-sudo-rule installs, and
    the blanket `(ALL : ALL) ALL` line that sits above it on most machines
    is not (it is exactly the one that costs a password)."""
    for line in strip_ansi(listing or "").splitlines():
        if "NOPASSWD:" in line and binary in line:
            return True
    return False


def verb_sudo_check():
    """Whether sudo would run the CLI's connect command as root without a
    password right now — the question a connect will ask a moment later.

    Asked as a plain `sudo -l` listing rather than `sudo -l <command>`:
    passing the command answers "may this user run it", and on any ordinary
    machine the blanket `(ALL : ALL) ALL` rule says yes to everything, so
    the probe read as "rule installed" on a machine that had none and the
    setup step it should have offered never appeared. The listing is what
    distinguishes a passwordless rule from a passworded one. -n never
    prompts, and -k ignores a credential cached by a recent terminal sudo,
    so a sudo that wants a password even to list reads as no rule rather
    than as fine for the next few minutes. No CLI call, no lock: the side
    channel's job."""
    sudo = os.environ.get("AEGIS_SUDO") or shutil.which("sudo") or "sudo"
    try:
        p = subprocess.run([sudo, "-n", "-k", "-l"], capture_output=True, text=True,
                           stdin=subprocess.DEVNULL, timeout=time_left(SUDO_CHECK_TIMEOUT))
    except (OSError, subprocess.SubprocessError) as exc:
        raise CliError("unknown", "sudo failed: %s" % exc)
    if p.returncode != 0:
        return {"ok": True, "allowed": False}
    return {"ok": True, "allowed": sudo_nopasswd_for(p.stdout, os.path.realpath(cli_path()))}



def verb_cli_path():
    """Where the adguardvpn-cli binary is, resolved exactly as every CLI call
    in here resolves it (cli_path) — for the commands Service.qml hands to a
    terminal the user watches.

    AdGuard's installer asks "Would you like to create a link in
    /usr/local/bin to the executable? [y/N]" and the default answer is no,
    which leaves the binary in /opt/adguardvpn_cli, writes a .nosymlink
    marker beside it and prints the full path as the way to run it. Every
    call in this helper survives that, because cli_path falls back to that
    directory — but `adguardvpn-cli login` typed into the user's own shell
    does not, and that is the panel's step 2. So the panel asks where the
    binary is instead of assuming the name resolves. No CLI call, no lock:
    the side channel's job."""
    binary = cli_path()
    if not (os.path.isfile(binary) and os.access(binary, os.X_OK)):
        raise CliError("cli_missing", "adguardvpn-cli not found")
    return {"ok": True, "path": os.path.realpath(binary)}


def verb_procs():
    """Unique process names owned by the current user, for the kill-switch autosuggest.

    ps gives the kernel comm (truncated to COMM_LEN); the executable's real
    basename from /proc/<pid>/exe is preferred when it is readable, so long
    names such as transmission-gtk are offered in full. Only a comm that IS
    COMM_LEN bytes can be a truncation, so those are the only ones looked up,
    and the answer is remembered per comm rather than read once per pid."""
    ps = os.environ.get("AEGIS_PS") or shutil.which("ps") or "ps"
    try:
        p = subprocess.run([ps, "-u", str(os.getuid()), "-o", "pid=,comm="], capture_output=True, text=True,
                           timeout=time_left(PROCS_TIMEOUT))
    except (OSError, subprocess.SubprocessError) as exc:
        raise CliError("unknown", "ps failed: %s" % exc)
    if p.returncode != 0:
        raise CliError("unknown", "ps exited %d" % p.returncode)
    seen = set()
    names = []
    full = {}  # comm -> the full name for it; one readlink per comm, not per pid
    for line in p.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) < 2:
            continue
        pid, comm = parts[0], parts[1].strip()
        name = comm
        # Only a comm the kernel had to truncate can have a longer real name,
        # and for a shorter one the exe could only ever match comm itself —
        # so /proc/<pid>/exe is read for those alone.
        if len(comm) == COMM_LEN:
            if comm in full:
                name = full[comm]
            else:
                try:
                    exe = os.path.basename(os.readlink(os.path.join(proc_root(), pid, "exe")))
                    if exe and exe[:COMM_LEN] == comm:
                        name = exe
                except OSError:
                    pass
                full[comm] = name
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
        return verb_home(rest)
    if verb == "config":
        return verb_config(rest)
    if verb == "update-check":
        return verb_update_check()
    if verb == "kill":
        return verb_kill(rest)
    if verb == "procs":
        return verb_procs()
    if verb == "sudo-check":
        return verb_sudo_check()
    if verb == "cli-path":
        return verb_cli_path()
    raise CliError("unknown", "unknown verb: %s" % (verb or "(none)"))


def main(argv=None):
    global _deadline
    argv = sys.argv[1:] if argv is None else argv
    budget = verb_budget(argv[0] if argv else "")
    if budget is not None:
        _deadline = time.monotonic() + budget
    # Quickshell's Process sends SIGTERM for `running = false` (Service.qml's
    # jobWatchdog); a Process torn down by a shell reload is SIGKILLed, which
    # nothing here can catch — that case relies on run_cli's CLI-held lock
    # and temp-file output instead.
    for sig in STOP_SIGNALS:
        signal.signal(sig, _on_stop)
    result = None
    try:
        try:
            result = dispatch(argv)
        except CliError as e:
            result = {"ok": False, "error": elide(e.message), "code": e.code}
        except Exception as e:  # never let a traceback reach the shell
            result = {"ok": False, "error": elide("%s: %s" % (type(e).__name__, e)), "code": "unknown"}
        for sig in STOP_SIGNALS:
            signal.signal(sig, signal.SIG_IGN)  # nothing left to stop; just answer
    except Stopped:
        # run_cli has already stopped and reaped its CLI child by now. A stop
        # that lands after the verb finished keeps the real answer.
        if result is None:
            result = {"ok": False, "error": "stopped waiting for adguardvpn-cli", "code": "timeout"}
    sys.stdout.write(json.dumps(result, ensure_ascii=False) + "\n")
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
