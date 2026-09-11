#!/usr/bin/env python3
"""Tests for agvpn.py: pure parsers against recorded fixtures, then every verb
end to end through tests/fake-cli.sh. Run from the plugin root:
    python3 -m unittest tests/agvpn_test.py
"""
import errno
import fcntl
import importlib.util
import json
import os
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from datetime import datetime
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
FIX = ROOT / "tests" / "fixtures"
FAKE = ROOT / "tests" / "fake-cli.sh"
HELPER = ROOT / "agvpn.py"

spec = importlib.util.spec_from_file_location("agvpn", HELPER)
agvpn = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agvpn)

_isolation = []


def setUpModule():
    # Without this, every test that doesn't set AEGIS_LOCK would take the lock
    # in the real session's $XDG_RUNTIME_DIR, and a home test that forgot
    # XDG_CACHE_HOME would read or write the user's real home.json.
    tmp = tempfile.TemporaryDirectory()
    runtime, cache = Path(tmp.name, "runtime"), Path(tmp.name, "cache")
    runtime.mkdir()
    runtime.chmod(0o700)
    env = mock.patch.dict(os.environ, {"XDG_RUNTIME_DIR": str(runtime), "XDG_CACHE_HOME": str(cache)})
    env.start()
    os.environ.pop("AEGIS_LOCK", None)
    _isolation.extend([env, tmp])


def tearDownModule():
    for item in _isolation:
        item.stop() if hasattr(item, "stop") else item.cleanup()
    _isolation.clear()


def fixture(name):
    return (FIX / name).read_text(encoding="utf-8")


class StripAnsi(unittest.TestCase):
    def test_removes_sgr_sequences(self):
        self.assertEqual(agvpn.strip_ansi("a\x1b[1mb\x1b[0mc\x1b[38;5;2md"), "abcd")


class ParseStatus(unittest.TestCase):
    def test_connected_upper_cases_city(self):
        s = agvpn.parse_status(fixture("status_connected.txt"))
        self.assertEqual(s, {"state": "connected", "location": "MONTREAL", "mode": "tun", "iface": "tun0", "listen": None})

    def test_connected_multi_word_city(self):
        s = agvpn.parse_status(fixture("status_connected_telaviv.txt"))
        self.assertEqual(s["location"], "TEL AVIV")

    def test_disconnected(self):
        s = agvpn.parse_status(fixture("status_disconnected.txt"))
        self.assertEqual(s, {"state": "disconnected", "location": None, "mode": None, "iface": None, "listen": None})

    def test_connecting(self):
        s = agvpn.parse_status(fixture("status_connecting.txt"))
        self.assertEqual(s["state"], "connecting")
        self.assertEqual(s["location"], "SYDNEY")

    def test_login_required(self):
        s = agvpn.parse_status(fixture("status_login.txt"))
        self.assertEqual(s["state"], "logged_out")

    def test_garbage_is_unknown(self):
        self.assertEqual(agvpn.parse_status("")["state"], "unknown")


class ParseLocations(unittest.TestCase):
    def setUp(self):
        self.rows = agvpn.parse_locations(fixture("list_locations.txt"))

    def test_row_count(self):
        self.assertEqual(len(self.rows), 81)

    def test_first_row_fields(self):
        self.assertEqual(self.rows[0]["iso"], "CA")
        self.assertEqual(self.rows[0]["country"], "Canada")
        self.assertEqual(self.rows[0]["cliName"], "Montreal")
        self.assertEqual(self.rows[0]["city"], "Montreal")
        self.assertIsInstance(self.rows[0]["pingMs"], int)

    def test_virtual_suffix_split(self):
        mumbai = [r for r in self.rows if r["iso"] == "IN"][0]
        self.assertEqual(mumbai["cliName"], "Mumbai (Virtual)")
        self.assertEqual(mumbai["city"], "Mumbai")
        self.assertTrue(mumbai["virtual"])
        self.assertFalse(self.rows[0]["virtual"])

    def test_diacritics_and_spaces_survive(self):
        names = {r["city"] for r in self.rows}
        self.assertIn("Chișinău", names)
        self.assertIn("São Paulo", names)
        self.assertIn("Silicon Valley", names)
        self.assertIn("Mexico City", names)

    def test_hint_and_blank_lines_ignored(self):
        self.assertTrue(all(r["iso"].isalpha() and len(r["iso"]) == 2 for r in self.rows))

    def test_narrower_columns_still_parse(self):
        text = ("ISO  COUNTRY        CITY              PING ESTIMATE\n"
                "US   United States  New York          22\n"
                "IN   India          Mumbai (Virtual)  900\n")
        rows = agvpn.parse_locations(text)
        self.assertEqual([r["cliName"] for r in rows], ["New York", "Mumbai (Virtual)"])
        self.assertEqual(rows[0]["country"], "United States")

    def test_missing_ping_is_none(self):
        text = "ISO   COUNTRY              CITY                           PING ESTIMATE\nUS    United States        New York                       \n"
        self.assertIsNone(agvpn.parse_locations(text)[0]["pingMs"])


class ParseLicense(unittest.TestCase):
    def test_logged_in(self):
        a = agvpn.parse_license(fixture("license.txt"))
        self.assertEqual(a, {"loggedIn": True, "email": "user@example.com", "plan": "PREMIUM",
                             "devices": 10, "validUntil": "2031-01-01"})

    def test_logged_out(self):
        a = agvpn.parse_license(fixture("license_logged_out.txt"))
        self.assertFalse(a["loggedIn"])
        self.assertEqual(a["email"], "")
        self.assertIsNone(a["devices"])


class ParseExclusions(unittest.TestCase):
    def test_empty_general(self):
        e = agvpn.parse_exclusions(fixture("exclusions_mode.txt"), fixture("exclusions_show_empty.txt"))
        self.assertEqual(e, {"mode": "general", "domains": []})

    def test_two_domains_selective(self):
        e = agvpn.parse_exclusions(fixture("exclusions_mode_selective.txt"), fixture("exclusions_show_two.txt"))
        self.assertEqual(e, {"mode": "selective", "domains": ["example.com", "*.bank.example"]})


class ParseTunnelTail(unittest.TestCase):
    def test_last_state_and_endpoint(self):
        t = agvpn.parse_tunnel_tail(fixture("tunnel_tail.txt"))
        self.assertEqual(t["state"], "disconnected")
        self.assertEqual(t["endpoint"], {"ip": "91.245.254.14", "port": 443, "pingMs": 44})
        self.assertEqual(t["connectedAt"], "10.09.2026 23:18:12.126302")

    def test_connected_when_last_state_connected(self):
        lines = fixture("tunnel_tail.txt").splitlines()
        cut = [l for l in lines if "23:18:1" in l]
        t = agvpn.parse_tunnel_tail("\n".join(cut))
        self.assertEqual(t["state"], "connected")

    def test_empty(self):
        self.assertEqual(agvpn.parse_tunnel_tail(""), {"state": None, "endpoint": None, "connectedAt": None})


class MatchLocation(unittest.TestCase):
    def setUp(self):
        self.locs = agvpn.load_locations(ROOT / "assets" / "locations.json")

    def test_socks_mode_status_is_connected_with_a_listen_address_and_no_iface(self):
        s = agvpn.parse_status(fixture("status_connected_socks.txt"))
        self.assertEqual(s["state"], "connected")
        self.assertEqual(s["location"], "ASTANA")
        self.assertEqual(s["mode"], "socks")
        self.assertIsNone(s["iface"])
        self.assertEqual(s["listen"], "127.0.0.1:1080")
        t = agvpn.parse_status(fixture("status_connected.txt"))
        self.assertEqual(t["mode"], "tun")
        self.assertEqual(t["listen"], None)

    def test_snapshot_reports_mode_and_listen_for_socks(self):
        with tempfile.TemporaryDirectory() as d:
            rc, out, _ = run_verb("snapshot", mode="socksconnected", env_extra={"data": d})
        data = json.loads(out)
        self.assertEqual(data["state"], "connected")
        self.assertEqual(data["mode"], "socks")
        self.assertEqual(data["listen"], "127.0.0.1:1080")
        self.assertIsNone(data["iface"])

    def test_upper_case_status_name(self):
        m = agvpn.match_location(self.locs, "TEL AVIV")
        self.assertEqual((m["iso"], m["city"]), ("IL", "Tel Aviv"))

    def test_virtual_suffix_and_diacritics(self):
        self.assertEqual(agvpn.match_location(self.locs, "Mumbai (Virtual)")["iso"], "IN")
        self.assertEqual(agvpn.match_location(self.locs, "chisinau")["iso"], "MD")
        self.assertEqual(agvpn.match_location(self.locs, "SÃO PAULO")["iso"], "BR")

    def test_unknown_is_none(self):
        self.assertIsNone(agvpn.match_location(self.locs, "Atlantis"))


class Counters(unittest.TestCase):
    def test_reads_sysfs_style_files(self):
        with tempfile.TemporaryDirectory() as d:
            stats = Path(d) / "statistics"
            stats.mkdir()
            (stats / "rx_bytes").write_text("123\n")
            (stats / "tx_bytes").write_text("456\n")
            self.assertEqual(agvpn.read_counters(Path(d)), (123, 456))

    def test_missing_iface_is_zero(self):
        self.assertEqual(agvpn.read_counters(Path("/nonexistent/tunX")), (0, 0))


FAKE_PS = ROOT / "tests" / "fake-ps.sh"


class ReadSince(unittest.TestCase):
    """The daemon (vpn.pid) outlives a location switch — tunnel_tail.txt shows
    one daemon serving several consecutive connects — so its own ps etimes is
    the daemon's uptime, not the current connection's. read_since must prefer
    the tunnel log's latest connect, only falling back to (or being floored
    by) the daemon's start time when the log has nothing usable."""

    def _stamp(self, epoch):
        return datetime.fromtimestamp(epoch).strftime(agvpn.LOG_STAMP)

    def test_several_connects_in_one_daemon_uses_the_latest_connect(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "vpn.pid").write_text("4242\n")
            now = time.time()
            last_connect = now - 60          # switched location a minute ago
            with mock.patch.dict(os.environ, {"AEGIS_PS": str(FAKE_PS), "FAKE_PS_ETIMES": "3600"}):
                since = agvpn.read_since(d, self._stamp(last_connect))
        self.assertAlmostEqual(since, int(last_connect), delta=2)

    def test_no_log_entries_falls_back_to_daemon_start(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "vpn.pid").write_text("4242\n")
            now = time.time()
            with mock.patch.dict(os.environ, {"AEGIS_PS": str(FAKE_PS), "FAKE_PS_ETIMES": "120"}):
                since = agvpn.read_since(d, None)
        self.assertAlmostEqual(since, int(now - 120), delta=2)

    def test_stale_log_older_than_daemon_uses_daemon_start(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "vpn.pid").write_text("4242\n")
            now = time.time()
            stale_connect = now - 7200       # a leftover line from a rotated-out daemon
            with mock.patch.dict(os.environ, {"AEGIS_PS": str(FAKE_PS), "FAKE_PS_ETIMES": "60"}):
                since = agvpn.read_since(d, self._stamp(stale_connect))
        self.assertAlmostEqual(since, int(now - 60), delta=2)

    def test_no_pid_file_falls_back_to_log(self):
        with tempfile.TemporaryDirectory() as d:
            now = time.time()
            since = agvpn.read_since(d, self._stamp(now - 30))
        self.assertAlmostEqual(since, int(now - 30), delta=2)

    def test_nothing_usable_is_none(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertIsNone(agvpn.read_since(d, None))
            self.assertIsNone(agvpn.read_since(d, "garbage"))


def run_verb(*args, mode="connected", env_extra=None, cli=None, timeout=None):
    env = dict(os.environ)
    env["AEGIS_CLI"] = cli or str(FAKE)
    env["FAKE_MODE"] = mode
    env["AEGIS_DATA_DIR"] = env_extra.get("data", "") if env_extra else ""
    if env_extra:
        env.update({k: v for k, v in env_extra.items() if k != "data"})
    cmd = [sys.executable, str(HELPER)] + list(args)
    if timeout is not None:
        env["AEGIS_TIMEOUT"] = str(timeout)
    p = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=90)
    return p.returncode, p.stdout, p.stderr


class Verbs(unittest.TestCase):
    def check_json(self, out):
        self.assertEqual(out.count("\n"), 1, "exactly one line of JSON expected: %r" % out)
        return json.loads(out)

    def test_snapshot_connected(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "tunnel.log").write_text(fixture("tunnel_tail.txt").replace(
                "23:29:21", "22:00:00"))  # keep the last state disconnected in the file
            rc, out, err = run_verb("snapshot", env_extra={"data": d})
        self.assertEqual(rc, 0)
        j = self.check_json(out)
        self.assertTrue(j["ok"])
        self.assertEqual(j["state"], "connected")
        self.assertEqual(j["location"], "Montreal")
        self.assertEqual(j["iso"], "CA")
        self.assertEqual(j["iface"], "tun0")
        self.assertEqual(j["endpoint"]["ip"], "91.245.254.14")
        self.assertIn("rx", j)
        self.assertIn("tx", j)

    def test_snapshot_disconnected(self):
        rc, out, _ = run_verb("snapshot", mode="disconnected")
        j = self.check_json(out)
        self.assertEqual(j["state"], "disconnected")
        self.assertIsNone(j["location"])
        self.assertIsNone(j["endpoint"])
        self.assertIsNone(j["sinceEpoch"])

    def test_snapshot_logged_out(self):
        rc, out, _ = run_verb("snapshot", mode="login")
        self.assertEqual(self.check_json(out)["state"], "logged_out")

    def test_locations_joined(self):
        rc, out, _ = run_verb("locations")
        j = self.check_json(out)
        self.assertTrue(j["ok"])
        self.assertEqual(len(j["locations"]), 81)
        tel = [l for l in j["locations"] if l["iso"] == "IL"][0]
        self.assertAlmostEqual(tel["lat"], 32.08)
        self.assertEqual(tel["cliName"], "Tel Aviv")
        mum = [l for l in j["locations"] if l["iso"] == "IN"][0]
        self.assertTrue(mum["virtual"])
        self.assertEqual(mum["cliName"], "Mumbai (Virtual)")

    def test_connect_passes_cli_name_and_returns_state(self):
        with tempfile.TemporaryDirectory() as d:
            log = Path(d, "argv.log")
            rc, out, _ = run_verb("connect", "Mumbai (Virtual)", env_extra={"FAKE_LOG": str(log)})
            argv = log.read_text()
        j = self.check_json(out)
        self.assertTrue(j["ok"])
        self.assertEqual(j["state"], "connected")
        self.assertIn("connect -l Mumbai (Virtual) -y --no-progress", argv)

    def test_connect_sudo_password(self):
        rc, out, _ = run_verb("connect", "Sydney", mode="sudo")
        j = self.check_json(out)
        self.assertFalse(j["ok"])
        self.assertEqual(j["code"], "sudo_password")
        self.assertLessEqual(len(j["error"]), 160)

    def test_connect_logged_out(self):
        rc, out, _ = run_verb("connect", "Sydney", mode="login")
        self.assertEqual(self.check_json(out)["code"], "logged_out")

    def test_disconnect(self):
        rc, out, _ = run_verb("disconnect", mode="disconnected")
        j = self.check_json(out)
        self.assertTrue(j["ok"])
        self.assertEqual(j["state"], "disconnected")

    def test_account(self):
        rc, out, _ = run_verb("account")
        j = self.check_json(out)
        self.assertTrue(j["loggedIn"])
        self.assertEqual(j["plan"], "PREMIUM")

    def test_account_logged_out_is_ok_true(self):
        rc, out, _ = run_verb("account", mode="login")
        j = self.check_json(out)
        self.assertTrue(j["ok"])
        self.assertFalse(j["loggedIn"])

    def test_logout(self):
        rc, out, _ = run_verb("logout")
        j = self.check_json(out)
        self.assertTrue(j["ok"])
        self.assertFalse(j["loggedIn"])

    def test_exclusions_show(self):
        rc, out, _ = run_verb("exclusions", "show", mode="selective")
        j = self.check_json(out)
        self.assertEqual(j["mode"], "selective")
        self.assertEqual(j["domains"], ["example.com", "*.bank.example"])

    def test_exclusions_add_reshows(self):
        with tempfile.TemporaryDirectory() as d:
            log = Path(d, "argv.log")
            rc, out, _ = run_verb("exclusions", "add", "example.com", mode="excl2", env_extra={"FAKE_LOG": str(log)})
            argv = log.read_text()
        j = self.check_json(out)
        self.assertTrue(j["ok"])
        self.assertIn("site-exclusions add example.com", argv)
        self.assertIn("site-exclusions show", argv)
        self.assertEqual(j["domains"], ["example.com", "*.bank.example"])

    def test_exclusions_mode_set(self):
        with tempfile.TemporaryDirectory() as d:
            log = Path(d, "argv.log")
            rc, out, _ = run_verb("exclusions", "mode", "selective", mode="selective", env_extra={"FAKE_LOG": str(log)})
            argv = log.read_text()
        self.assertIn("site-exclusions mode selective", argv)
        self.assertEqual(self.check_json(out)["mode"], "selective")

    def test_exclusions_mode_rejects_bad_value(self):
        rc, out, _ = run_verb("exclusions", "mode", "bogus")
        j = self.check_json(out)
        self.assertFalse(j["ok"])
        self.assertEqual(j["code"], "unknown")

    def test_timeout_code(self):
        rc, out, _ = run_verb("snapshot", mode="hang", timeout=1)
        j = self.check_json(out)
        self.assertEqual(rc, 0)
        self.assertFalse(j["ok"])
        self.assertEqual(j["code"], "timeout")

    def test_cli_missing(self):
        rc, out, _ = run_verb("snapshot", cli="/nonexistent/adguardvpn-cli")
        j = self.check_json(out)
        self.assertEqual(rc, 0)
        self.assertEqual(j["code"], "cli_missing")

    def test_unknown_verb(self):
        rc, out, _ = run_verb("frobnicate")
        j = self.check_json(out)
        self.assertEqual(rc, 0)
        self.assertFalse(j["ok"])

    def test_home_skips_lookup_while_connected(self):
        with tempfile.TemporaryDirectory() as d:
            rc, out, _ = run_verb("home", env_extra={"XDG_CACHE_HOME": d, "AEGIS_CURL": "/bin/false"})
            cache = list(Path(d).rglob("home.json"))
        j = self.check_json(out)
        self.assertTrue(j["ok"])
        self.assertIsNone(j["home"])
        self.assertTrue(j["stale"])
        self.assertEqual(cache, [])

    def test_home_uses_cache_when_present(self):
        with tempfile.TemporaryDirectory() as d:
            cdir = Path(d, "io.github.nimbleaininja.aegis")
            cdir.mkdir()
            (cdir / "home.json").write_text(json.dumps({"lat": 1.5, "lon": 2.5, "city": "X", "iso": "XX",
                                                        "gateway": "gw", "fetchedAt": 0}))
            rc, out, _ = run_verb("home", env_extra={"XDG_CACHE_HOME": d, "AEGIS_CURL": "/bin/false"})
        j = self.check_json(out)
        self.assertEqual(j["home"], {"lat": 1.5, "lon": 2.5, "city": "X", "iso": "XX"})
        self.assertTrue(j["stale"])

    def test_home_fetches_when_disconnected_and_no_cache(self):
        with tempfile.TemporaryDirectory() as d:
            curl = Path(d, "curl")
            curl.write_text('#!/bin/sh\necho \'{"ip":"1.2.3.4","city":"Haifa","country":"IL","loc":"32.79,34.99"}\'\n')
            curl.chmod(0o755)
            rc, out, _ = run_verb("home", mode="disconnected", env_extra={"XDG_CACHE_HOME": d, "AEGIS_CURL": str(curl)})
            cache = json.loads(Path(d, "io.github.nimbleaininja.aegis", "home.json").read_text())
        j = self.check_json(out)
        self.assertEqual(j["home"], {"lat": 32.79, "lon": 34.99, "city": "Haifa", "iso": "IL"})
        self.assertFalse(j["stale"])
        self.assertEqual(cache["city"], "Haifa")

    def test_home_curl_failure_is_ok_false_network(self):
        with tempfile.TemporaryDirectory() as d:
            rc, out, _ = run_verb("home", mode="disconnected", env_extra={"XDG_CACHE_HOME": d, "AEGIS_CURL": "/bin/false"})
        j = self.check_json(out)
        self.assertFalse(j["ok"])
        self.assertEqual(j["code"], "network")


class ParseConfig(unittest.TestCase):
    def test_defaults_resolve(self):
        c = agvpn.parse_config(fixture("config_show.txt"))
        self.assertEqual(c["mode"], "tun")
        self.assertEqual(c["socksHost"], "127.0.0.1")
        self.assertEqual(c["socksPort"], 1080)
        self.assertEqual(c["socksUsername"], "")
        self.assertEqual(c["dns"], "default")
        self.assertFalse(c["changeSystemDns"])
        self.assertEqual(c["protocol"], "auto")
        self.assertTrue(c["postQuantum"])
        self.assertTrue(c["showHints"])
        self.assertEqual(c["updateChannel"], "release")
        self.assertEqual(c["tunRouting"], "auto")

    def test_explicit_socks_values(self):
        c = agvpn.parse_config(fixture("config_show_socks.txt"))
        self.assertEqual(c["mode"], "socks")
        self.assertEqual(c["socksHost"], "0.0.0.0")
        self.assertEqual(c["socksPort"], 1085)
        self.assertEqual(c["socksUsername"], "proxyuser")
        self.assertEqual(c["dns"], "https://dns.adguard-dns.com/dns-query")
        self.assertTrue(c["changeSystemDns"])
        self.assertEqual(c["protocol"], "quic")
        self.assertFalse(c["postQuantum"])
        self.assertFalse(c["showHints"])
        self.assertEqual(c["updateChannel"], "beta")

    def test_garbage_gives_defaults(self):
        c = agvpn.parse_config("")
        self.assertEqual(c["mode"], "tun")
        self.assertEqual(c["protocol"], "auto")


class ParseUpdate(unittest.TestCase):
    def test_up_to_date(self):
        u = agvpn.parse_update(fixture("check_update_latest.txt"), "AdGuard VPN CLI v1.7.12")
        self.assertEqual(u, {"upToDate": True, "current": "1.7.12", "latest": None})

    def test_new_version(self):
        u = agvpn.parse_update(fixture("check_update_new.txt"), "AdGuard VPN CLI v1.7.12")
        self.assertEqual(u, {"upToDate": False, "current": "1.7.12", "latest": "1.8.3"})

    def test_unrecognised_output_is_indeterminate_not_up_to_date(self):
        # e.g. no network: --version still answers (it needs none) but
        # check-update's own output isn't a recognised message, so this must
        # not be reported as upToDate: True.
        u = agvpn.parse_update(fixture("check_update_failed.txt"), "AdGuard VPN CLI v1.7.12")
        self.assertIsNone(u["upToDate"])
        self.assertEqual(u["current"], "1.7.12")
        self.assertIsNone(u["latest"])


class ConfigVerbs(unittest.TestCase):
    check_json = Verbs.check_json

    def test_config_show(self):
        rc, out, _ = run_verb("config", "show")
        j = self.check_json(out)
        self.assertTrue(j["ok"])
        self.assertEqual(j["mode"], "tun")
        self.assertEqual(j["protocol"], "auto")
        self.assertTrue(j["postQuantum"])

    def test_config_show_socks_mode(self):
        rc, out, _ = run_verb("config", "show", mode="socks")
        j = self.check_json(out)
        self.assertEqual(j["mode"], "socks")
        self.assertEqual(j["socksUsername"], "proxyuser")

    def assert_set(self, key, value, expected_argv, mode="connected"):
        with tempfile.TemporaryDirectory() as d:
            log = Path(d, "argv.log")
            rc, out, _ = run_verb("config", "set", key, value, mode=mode, env_extra={"FAKE_LOG": str(log)})
            argv = log.read_text()
        j = self.check_json(out)
        self.assertTrue(j["ok"], j)
        self.assertIn(expected_argv, argv)
        self.assertIn("config show", argv)
        return j

    def test_config_set_each_key(self):
        self.assert_set("mode", "socks", "config set-mode socks")
        self.assert_set("protocol", "quic", "config set-protocol quic")
        self.assert_set("postQuantum", "false", "config set-post-quantum off")
        self.assert_set("postQuantum", "on", "config set-post-quantum on")
        self.assert_set("dns", "default", "config set-dns default")
        self.assert_set("dns", "https://dns.adguard-dns.com/dns-query", "config set-dns https://dns.adguard-dns.com/dns-query")
        self.assert_set("changeSystemDns", "true", "config set-change-system-dns on")
        self.assert_set("socksHost", "0.0.0.0", "config set-socks-host 0.0.0.0")
        self.assert_set("socksPort", "1085", "config set-socks-port 1085")
        self.assert_set("socksUsername", "proxyuser", "config set-socks-username proxyuser")
        self.assert_set("socksPassword", "s3cret", "config set-socks-password s3cret")
        self.assert_set("socksAuth", "clear", "config clear-socks-auth")

    def test_config_set_rejects_bad_input_without_running(self):
        for key, value in (("mode", "pptp"), ("protocol", "smoke"), ("socksPort", "abc"),
                           ("socksPort", "70000"), ("postQuantum", "maybe"), ("nope", "x"), ("dns", "")):
            with tempfile.TemporaryDirectory() as d:
                log = Path(d, "argv.log")
                rc, out, _ = run_verb("config", "set", key, value, env_extra={"FAKE_LOG": str(log)})
                ran = log.exists()
            j = self.check_json(out)
            self.assertFalse(j["ok"], (key, value))
            self.assertEqual(j["code"], "unknown")
            self.assertFalse(ran, "must not touch the CLI for %s=%s" % (key, value))

    def test_update_check_latest(self):
        rc, out, _ = run_verb("update-check")
        j = self.check_json(out)
        self.assertTrue(j["ok"])
        self.assertTrue(j["upToDate"])
        self.assertEqual(j["current"], "1.7.12")
        self.assertIsNone(j["latest"])

    def test_update_check_new(self):
        rc, out, _ = run_verb("update-check", mode="newversion")
        j = self.check_json(out)
        self.assertFalse(j["upToDate"])
        self.assertEqual(j["latest"], "1.8.3")

    def test_update_check_failure_is_ok_false_not_up_to_date(self):
        rc, out, _ = run_verb("update-check", mode="updatefail")
        j = self.check_json(out)
        self.assertFalse(j["ok"])
        self.assertNotIn("upToDate", j)
        self.assertIn(j["code"], ("parse", "network"))
        self.assertLessEqual(len(j["error"]), 160)

    def test_kill_uses_exact_names_only(self):
        with tempfile.TemporaryDirectory() as d:
            log = Path(d, "argv.log")
            rc, out, _ = run_verb("kill", "sleepy", "ghost", "bad name", "",
                                  env_extra={"FAKE_LOG": str(log), "AEGIS_PKILL": str(ROOT / "tests" / "fake-pkill.sh")})
            argv = log.read_text()
        j = self.check_json(out)
        self.assertTrue(j["ok"])
        self.assertEqual(j["killed"], ["sleepy"])
        self.assertEqual(j["missing"], ["ghost"])
        self.assertEqual(j["rejected"], ["bad name"])
        self.assertEqual(j["skipped"], [])
        self.assertIn("pkill -x -- sleepy", argv)
        self.assertNotIn("-f", argv)
        self.assertNotIn("bad name", argv)

    def test_kill_refuses_denylisted_names_even_when_well_formed(self):
        with tempfile.TemporaryDirectory() as d:
            log = Path(d, "argv.log")
            # "SUDO" and "Hyprland" aren't the exact-case entries pkill -x
            # would ever be asked to match against here — the deny check
            # must still catch them case-insensitively, before pkill runs.
            rc, out, _ = run_verb("kill", "bash", "Hyprland", "SUDO", "adguardvpn-cli", "sleepy",
                                  env_extra={"FAKE_LOG": str(log), "AEGIS_PKILL": str(ROOT / "tests" / "fake-pkill.sh")})
            argv = log.read_text()
        j = self.check_json(out)
        self.assertTrue(j["ok"])
        self.assertEqual(j["killed"], ["sleepy"])
        self.assertEqual(j["missing"], [])
        self.assertEqual(j["rejected"], [])
        self.assertEqual(sorted(j["skipped"]), sorted(["bash", "Hyprland", "SUDO", "adguardvpn-cli"]))
        self.assertNotIn("bash", argv)
        self.assertNotIn("Hyprland", argv)
        self.assertNotIn("SUDO", argv)
        self.assertNotIn("adguardvpn-cli", argv)

    def test_kill_denylist_prefixes_and_is_case_insensitive(self):
        for name in ("systemd-logind", "SYSTEMD-LOGIND", "pipewire-pulse", "dbus-broker-launch"):
            self.assertTrue(agvpn._is_denied(name), name)
        for name in ("firefox", "sleepy", "transmission-gtk"):
            self.assertFalse(agvpn._is_denied(name), name)

    def test_kill_denylist_covers_session_and_security_critical_additions(self):
        # hyprlock/hypridle in particular: killing the lock screen on a VPN
        # drop would UNLOCK the session instead of protecting it.
        for name in ("hyprlock", "HYPRLOCK", "hypridle", "uwsm", "Xwayland", "xwayland",
                     "xdg-desktop-portal-hyprland", "xdg-desktop-portal-gtk",
                     "polkit", "polkitd", "hyprpolkitagent",
                     "gnome-keyring-daemon", "ssh-agent", "gpg-agent", "login", "agetty",
                     "swayosd-server", "mako", "walker", "elephant"):
            self.assertTrue(agvpn._is_denied(name), name)

    def test_kill_denylist_catches_the_kernel_truncated_comm_of_a_long_denied_name(self):
        # ps/pkill -x only ever see gnome-keyring-daemon truncated to
        # COMM_LEN bytes; the truncated spelling itself must be denied too.
        self.assertTrue(agvpn._is_denied("gnome-keyring-d"), "truncated comm of a denied name")
        self.assertFalse(agvpn._is_denied("gnome-keyring"), "a shorter, unrelated name must not be denied")
        self.assertFalse(agvpn._is_denied("gnome-keyring-daemon-extra"), "a longer, unrelated name must not be denied")

    def test_kill_skips_the_truncated_comm_of_a_long_denied_name(self):
        with tempfile.TemporaryDirectory() as d:
            log = Path(d, "argv.log")
            rc, out, _ = run_verb("kill", "gnome-keyring-d", "sleepy",
                                  env_extra={"FAKE_LOG": str(log), "AEGIS_PKILL": str(ROOT / "tests" / "fake-pkill.sh")})
            argv = log.read_text()
        j = self.check_json(out)
        self.assertTrue(j["ok"])
        self.assertEqual(j["killed"], ["sleepy"])
        self.assertEqual(j["skipped"], ["gnome-keyring-d"])
        self.assertNotIn("gnome-keyring", argv)

    def test_procs_lists_unique_sorted_user_process_names(self):
        with tempfile.TemporaryDirectory() as proc:
            os.makedirs(os.path.join(proc, "42"))
            os.symlink("/usr/bin/transmission-gtk", os.path.join(proc, "42", "exe"))
            rc, out, _ = run_verb("procs", env_extra={"AEGIS_PS": str(ROOT / "tests" / "fake-ps.sh"), "AEGIS_PROC": proc})
        self.assertEqual(rc, 0)
        data = self.check_json(out)
        self.assertTrue(data["ok"])
        # full executable name from /proc/<pid>/exe wins over the truncated comm
        self.assertEqual(data["procs"], ["firefox", "foot", "nvim", "Signal", "transmission-gtk"])

    def test_procs_dbus_broker_prefix_is_denied(self):
        rc, out, _ = run_verb("procs", env_extra={"AEGIS_PS": str(ROOT / "tests" / "fake-ps.sh")})
        self.assertNotIn("dbus-broker-lau", self.check_json(out)["procs"])

    def test_kill_truncates_long_names_to_the_kernel_comm_length(self):
        with tempfile.TemporaryDirectory() as d:
            log = Path(d, "argv.log")
            rc, out, _ = run_verb("kill", "transmission-gtk", "sleepy",
                                  env_extra={"FAKE_LOG": str(log), "AEGIS_PKILL": str(ROOT / "tests" / "fake-pkill.sh")})
            argv = log.read_text().splitlines()
        data = self.check_json(out)
        self.assertIn("pkill -x -- transmission-gt", argv)
        self.assertIn("pkill -x -- sleepy", argv)
        self.assertEqual(data["killed"], ["sleepy"])
        self.assertEqual(data["missing"], ["transmission-gtk"])

    def test_procs_failing_ps_is_an_error(self):
        rc, out, _ = run_verb("procs", env_extra={"FAKE_PS_FAIL": "1", "AEGIS_PS": str(ROOT / "tests" / "fake-ps.sh")})
        j = self.check_json(out)
        self.assertFalse(j["ok"])
        self.assertEqual(j["code"], "unknown")
        self.assertIn("ps", j["error"])
        self.assertNotIn("verb", j["error"])

    def test_procs_missing_ps_is_an_error(self):
        rc, out, _ = run_verb("procs", env_extra={"AEGIS_PS": "/nonexistent/ps"})
        j = self.check_json(out)
        self.assertFalse(j["ok"])
        self.assertEqual(j["code"], "unknown")
        self.assertIn("ps", j["error"])
        self.assertNotIn("verb", j["error"])

    def test_kill_nothing_is_ok(self):
        rc, out, _ = run_verb("kill", env_extra={"AEGIS_PKILL": str(ROOT / "tests" / "fake-pkill.sh")})
        j = self.check_json(out)
        self.assertTrue(j["ok"])
        self.assertEqual(j["killed"], [])


class Serialization(unittest.TestCase):
    def test_concurrent_helpers_never_overlap_cli_calls(self):
        import threading
        with tempfile.TemporaryDirectory() as d:
            log = Path(d, "cli.log")
            env = {"FAKE_LOG": str(log), "AEGIS_LOCK": str(Path(d, "cli.lock")), "data": d}
            threads = [threading.Thread(target=run_verb, args=("snapshot",), kwargs={"mode": "slow", "env_extra": env}) for _ in range(3)]
            for t in threads: t.start()
            for t in threads: t.join()
            lines = log.read_text().splitlines()
        events = [(l.split()[0], float(l.split()[1])) for l in lines if l.startswith(("start ", "end "))]
        self.assertEqual(len([e for e in events if e[0] == "start"]), 3)
        depth = 0
        for kind, _ in sorted(events, key=lambda e: e[1]):
            depth += 1 if kind == "start" else -1
            self.assertLessEqual(depth, 1, "two adguardvpn-cli processes were running at once")

    def test_slow_multi_call_verbs_never_overlap_and_all_finish(self):
        import threading
        with tempfile.TemporaryDirectory() as d:
            log = Path(d, "cli.log")
            env = {"FAKE_LOG": str(log), "AEGIS_LOCK": str(Path(d, "cli.lock")), "data": d}
            outs = []
            jobs = [("exclusions", "add", "example.com"), ("disconnect",), ("snapshot",)]
            threads = [threading.Thread(target=lambda a=a: outs.append(run_verb(*a, mode="slow", env_extra=env)[1]))
                       for a in jobs]
            for t in threads: t.start()
            for t in threads: t.join()
            lines = log.read_text().splitlines()
        self.assertEqual([json.loads(o)["ok"] for o in outs], [True, True, True], outs)
        assert_serialized(self, lines, 6)


def assert_serialized(test, lines, starts=None):
    events = sorted(((l.split()[0], float(l.split()[1])) for l in lines if l.startswith(("start ", "end "))),
                    key=lambda e: e[1])
    if starts is not None:
        test.assertEqual(len([e for e in events if e[0] == "start"]), starts)
    depth = 0
    for kind, _ in events:
        depth += 1 if kind == "start" else -1
        test.assertLessEqual(depth, 1, "two adguardvpn-cli processes were running at once")


class Budgets(unittest.TestCase):
    """agvpn.py is the authority on how long a verb may take; Model.js only
    copies verb_budgets() for the watchdog (checked in tests/model.test.js)."""

    # Non-CLI sub-calls on each verb's longest path.
    EXTRA = {"snapshot": agvpn.PS_TIMEOUT, "home": agvpn.ROUTE_TIMEOUT + agvpn.CURL_TIMEOUT}
    SAMPLES = [
        (("snapshot",), "connected"), (("locations",), "connected"), (("connect", "Sydney"), "connected"),
        (("disconnect",), "disconnected"), (("account",), "connected"), (("logout",), "connected"),
        (("exclusions", "show"), "connected"), (("exclusions", "add", "example.com"), "excl2"),
        (("exclusions", "remove", "example.com"), "connected"), (("exclusions", "mode", "general"), "connected"),
        (("home",), "connected"), (("config", "show"), "connected"), (("config", "set", "mode", "socks"), "connected"),
        (("update-check",), "connected"),
    ]

    def test_every_budget_covers_the_calls_the_verb_actually_makes(self):
        for args, mode in self.SAMPLES:
            with tempfile.TemporaryDirectory() as d:
                log = Path(d, "argv.log")
                run_verb(*args, mode=mode, env_extra={"FAKE_LOG": str(log), "AEGIS_LOCK": str(Path(d, "cli.lock")),
                                                      "XDG_CACHE_HOME": d, "AEGIS_CURL": "/bin/false"})
                calls = log.read_text().splitlines()
            self.assertTrue(calls, args)
            worst = sum(agvpn.CONNECT_TIMEOUT if c.startswith("connect ") else agvpn.CLI_TIMEOUT for c in calls)
            worst += agvpn.CLI_TIMEOUT + self.EXTRA.get(args[0], 0)  # + one call's worth of lock wait
            self.assertLessEqual(worst, agvpn.verb_budget(args[0]), "%s makes %d CLI calls" % (" ".join(args), len(calls)))

    def test_queued_verbs_have_budgets_kill_and_unknown_do_not(self):
        for verb in ("snapshot", "locations", "connect", "disconnect", "account", "logout",
                     "exclusions", "home", "config", "update-check", "procs"):
            self.assertIsNotNone(agvpn.verb_budget(verb), verb)
        self.assertIsNone(agvpn.verb_budget("kill"))
        self.assertIsNone(agvpn.verb_budget("frobnicate"))
        self.assertGreaterEqual(agvpn.verb_budget("exclusions"), 3 * agvpn.CLI_TIMEOUT)
        self.assertGreaterEqual(agvpn.verb_budget("connect"), agvpn.CONNECT_TIMEOUT + agvpn.CLI_TIMEOUT)
        with mock.patch.dict(os.environ, {"AEGIS_TIMEOUT": "1"}):
            self.assertEqual(agvpn.verb_budget("disconnect"), 3)  # lock wait + disconnect + status
        with mock.patch.dict(os.environ, {"AEGIS_BUDGET": "2.5"}):
            self.assertEqual(agvpn.verb_budget("connect"), 2.5)
            self.assertIsNone(agvpn.verb_budget("kill"))

    def test_lock_wait_counts_toward_the_budget(self):
        with tempfile.TemporaryDirectory() as d:
            lock_file, log = Path(d, "cli.lock"), Path(d, "argv.log")
            fd = os.open(lock_file, os.O_RDWR | os.O_CREAT)
            try:
                fcntl.lockf(fd, fcntl.LOCK_EX)  # stands in for another helper's running CLI
                started = time.monotonic()
                rc, out, _ = run_verb("snapshot", env_extra={"AEGIS_LOCK": str(lock_file), "AEGIS_BUDGET": "0.8",
                                                             "FAKE_LOG": str(log)})
                elapsed = time.monotonic() - started
            finally:
                os.close(fd)
            ran = log.exists()
        j = json.loads(out)
        self.assertFalse(j["ok"])
        self.assertEqual(j["code"], "timeout")
        self.assertLess(elapsed, 4)
        self.assertFalse(ran, "the CLI must not start once the budget is spent waiting")

    def test_sub_calls_are_clipped_to_what_is_left_of_the_budget(self):
        # hang outlasts CLI_TIMEOUT (12 s) on each of the three calls; the
        # 1 s budget has to cut the very first one short.
        with tempfile.TemporaryDirectory() as d:
            started = time.monotonic()
            rc, out, _ = run_verb("exclusions", "add", "example.com", mode="hang",
                                  env_extra={"AEGIS_LOCK": str(Path(d, "cli.lock")), "AEGIS_BUDGET": "1"})
            elapsed = time.monotonic() - started
        self.assertEqual(json.loads(out)["code"], "timeout")
        self.assertLess(elapsed, 5)


class CliLifecycle(unittest.TestCase):
    """A stopped or killed helper must never leave an adguardvpn-cli that
    overlaps the next job's, nor one that dies writing to a dead pipe."""

    def start_helper(self, d, *args, **extra):
        pidfile = Path(d, "cli.pid")
        env = dict(os.environ, AEGIS_CLI=str(FAKE), FAKE_MODE="linger", AEGIS_DATA_DIR=d,
                   AEGIS_LOCK=str(Path(d, "cli.lock")), FAKE_LOG=str(Path(d, "cli.log")), FAKE_PIDFILE=str(pidfile))
        env.update(extra)
        p = subprocess.Popen([sys.executable, str(HELPER)] + list(args), stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, text=True, env=env)

        def cleanup():
            if p.poll() is None:
                p.kill()
            if not p.stdout.closed:
                p.stdout.close()
            p.wait()
        self.addCleanup(cleanup)
        until = time.monotonic() + 10
        while not (pidfile.exists() and pidfile.read_text().strip()):
            self.assertLess(time.monotonic(), until, "fake CLI never started")
            time.sleep(0.02)
        return p, int(pidfile.read_text())

    def alive(self, pid):
        try:
            state = Path("/proc/%d/stat" % pid).read_text().rsplit(")", 1)[1].split()[0]
        except OSError:
            return False
        return state != "Z"

    def lock_free(self, d):
        fd = os.open(Path(d, "cli.lock"), os.O_RDWR | os.O_CREAT)
        try:
            return agvpn._lock_free(fd)
        finally:
            os.close(fd)

    def test_sigterm_stops_and_reaps_the_cli_before_answering(self):
        with tempfile.TemporaryDirectory() as d:
            helper, cli = self.start_helper(d, "disconnect")
            started = time.monotonic()
            helper.send_signal(signal.SIGTERM)  # what Process `running = false` sends
            out, _ = helper.communicate(timeout=10)
            elapsed = time.monotonic() - started
            self.assertFalse(self.alive(cli), "the fake CLI outlived its helper")
            self.assertTrue(self.lock_free(d))
            rc, nxt, _ = run_verb("snapshot", mode="disconnected",
                                  env_extra={"data": d, "AEGIS_LOCK": str(Path(d, "cli.lock"))})
        j = json.loads(out)
        self.assertFalse(j["ok"])
        self.assertEqual(j["code"], "timeout")
        self.assertLess(elapsed, 2.5)
        self.assertEqual(json.loads(nxt)["state"], "disconnected")

    def test_sigterm_escalates_to_sigkill_for_a_cli_that_ignores_it(self):
        with tempfile.TemporaryDirectory() as d:
            helper, cli = self.start_helper(d, "disconnect", FAKE_IGNORE_TERM="1", FAKE_SLEEP="3",
                                            AEGIS_STOP_GRACE="0.3")
            started = time.monotonic()
            helper.send_signal(signal.SIGTERM)
            out, _ = helper.communicate(timeout=10)
            elapsed = time.monotonic() - started
            self.assertFalse(self.alive(cli))
            self.assertTrue(self.lock_free(d))
        self.assertEqual(json.loads(out)["code"], "timeout")
        self.assertLess(elapsed, 2.5)

    def test_killed_helper_leaves_a_cli_that_keeps_the_lock_and_can_still_write(self):
        with tempfile.TemporaryDirectory() as d:
            helper, cli = self.start_helper(d, "locations", FAKE_SLEEP="1.5")
            helper.kill()          # what Quickshell does to a Process on shell reload
            helper.communicate()   # and nobody reads its output any more
            self.assertTrue(self.alive(cli), "the orphaned CLI should run to completion")
            self.assertFalse(self.lock_free(d), "the orphaned CLI must still hold the lock")
            rc, out, _ = run_verb("snapshot", mode="slow", env_extra={
                "data": d, "AEGIS_LOCK": str(Path(d, "cli.lock")), "FAKE_LOG": str(Path(d, "cli.log"))})
            lines = Path(d, "cli.log").read_text().splitlines()
        self.assertTrue(json.loads(out)["ok"])
        assert_serialized(self, lines, 2)
        orphan_end = [l.split() for l in lines if l.startswith("end ") and len(l.split()) == 3]
        self.assertEqual(len(orphan_end), 1, lines)
        self.assertEqual(orphan_end[0][2], "0", "the orphaned CLI's output write failed (dead pipe?)")

    def test_cli_output_goes_to_files_not_pipes_and_still_parses(self):
        with tempfile.TemporaryDirectory() as d:
            fds = Path(d, "fds")
            env = {"AEGIS_CLI": str(FAKE), "FAKE_MODE": "connected", "FAKE_FDS": str(fds),
                   "AEGIS_LOCK": str(Path(d, "cli.lock"))}
            with mock.patch.dict(os.environ, env):
                rc, out, err = agvpn.run_cli(["list-locations"])
                targets = fds.read_text().splitlines()
                rc2, out2, err2 = agvpn.run_cli(["bogus"])
        self.assertEqual(rc, 0)
        self.assertEqual(len(agvpn.parse_locations(out)), 81)
        self.assertEqual(err, "")
        self.assertEqual(rc2, 106)
        self.assertIn("not expected", err2)
        self.assertEqual(out2, "")
        self.assertEqual(len(targets), 2)
        for target in targets:
            self.assertNotIn("pipe:", target)


class PrivateState(unittest.TestCase):
    """The CLI lock and home.json only live where no other local user can
    reach them. A symlink, a directory or file that isn't ours, or a
    group/world-writable runtime dir is refused or skipped — never followed,
    and never a reason to run the CLI unlocked."""

    CURL = '#!/bin/sh\necho \'{"city":"Haifa","country":"IL","loc":"32.79,34.99"}\'\n'

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.runtime = self.root / "runtime"
        self.runtime.mkdir()
        self.runtime.chmod(0o700)
        self.cache = self.root / "cache"
        self.app_dir = self.cache / agvpn.PLUGIN_ID
        self.victim = self.root / "victim"  # where another user would like us to write
        self.victim.mkdir()
        self.env = {"XDG_RUNTIME_DIR": str(self.runtime), "XDG_CACHE_HOME": str(self.cache)}
        self.runtime_lock = self.runtime / ("aegis-cli-%d.lock" % os.getuid())
        self.fallback_lock = self.app_dir / "cli.lock"

    def mode(self, path):
        return stat.S_IMODE(os.lstat(path).st_mode)

    def lock_path(self, **env):
        with mock.patch.dict(os.environ, dict(self.env, **env)):
            return agvpn.lock_path()

    def run_snapshot(self, **env):
        log = self.root / "argv.log"
        rc, out, _ = run_verb("snapshot", mode="disconnected", env_extra=dict(self.env, FAKE_LOG=str(log), **env))
        ran = log.exists()
        if ran:
            log.unlink()
        return json.loads(out), ran

    def assert_refused(self, j, ran, what="refusing to use untrusted lock path"):
        self.assertFalse(j["ok"], j)
        self.assertEqual(j["code"], "unknown")
        self.assertIn(what, j["error"])
        self.assertFalse(ran, "the CLI must never run without its lock")

    # ------------------------------------------------------ lock location --

    def test_a_valid_runtime_dir_holds_the_lock(self):
        self.assertEqual(self.lock_path(), str(self.runtime_lock))
        self.assertFalse(self.cache.exists(), "the fallback isn't needed, so it isn't created")

    def test_a_symlinked_runtime_dir_is_ignored_for_the_private_cache_dir(self):
        link = self.root / "runtime-link"
        link.symlink_to(self.runtime)
        for value in (str(link), str(link) + "/"):  # a trailing slash must not make lstat follow it
            self.assertEqual(self.lock_path(XDG_RUNTIME_DIR=value), str(self.fallback_lock), value)
        self.assertEqual(self.mode(self.app_dir), 0o700)

    def test_a_group_or_world_writable_runtime_dir_is_ignored(self):
        for m in (0o777, 0o770, 0o702):
            self.runtime.chmod(m)
            self.assertEqual(self.lock_path(), str(self.fallback_lock), oct(m))
        self.assertEqual(self.mode(self.runtime), 0o702, "not ours to chmod")

    def test_an_unset_relative_missing_or_non_directory_runtime_dir_is_ignored(self):
        not_a_dir = self.root / "file"
        not_a_dir.write_text("")
        for value in ("", "run/user/1000", str(self.root / "missing"), str(not_a_dir)):
            self.assertEqual(self.lock_path(XDG_RUNTIME_DIR=value), str(self.fallback_lock), value)

    def test_a_runtime_dir_owned_by_someone_else_is_ignored(self):
        real_lstat = os.lstat

        def foreign(path, *args, **kwargs):
            st = real_lstat(path, *args, **kwargs)
            if os.fspath(path) != str(self.runtime):
                return st
            fields = list(st[:10])
            fields[4] = st.st_uid + 1  # st_uid
            return os.stat_result(fields)
        with mock.patch.object(agvpn.os, "lstat", side_effect=foreign):
            self.assertEqual(self.lock_path(), str(self.fallback_lock))

    def test_the_fallback_dir_is_created_0700_and_an_existing_wider_one_tightened(self):
        self.assertEqual(self.lock_path(XDG_RUNTIME_DIR=""), str(self.fallback_lock))
        self.assertEqual(self.mode(self.app_dir), 0o700)
        self.app_dir.chmod(0o755)
        self.assertEqual(self.lock_path(XDG_RUNTIME_DIR=""), str(self.fallback_lock))
        self.assertEqual(self.mode(self.app_dir), 0o700)

    def test_private_dir_refuses_a_directory_owned_by_someone_else_without_touching_it(self):
        self.app_dir.mkdir(parents=True)
        self.app_dir.chmod(0o755)
        with mock.patch.object(agvpn.os, "getuid", return_value=os.getuid() + 1):
            with self.assertRaises(agvpn.UntrustedPath):
                agvpn.private_dir(self.app_dir)
        self.assertEqual(self.mode(self.app_dir), 0o755)

    # ------------------------------------------------------ lock refusals --

    def test_a_symlink_at_the_fallback_dir_is_refused_and_nothing_is_created_behind_it(self):
        self.cache.mkdir()
        for target in (self.victim, self.victim / "not-yet"):  # an existing and a dangling target
            self.app_dir.symlink_to(target)
            self.assert_refused(*self.run_snapshot(XDG_RUNTIME_DIR=""))
            self.assertEqual(list(self.victim.iterdir()), [])
            self.assertTrue(self.app_dir.is_symlink())
            self.app_dir.unlink()

    def test_a_file_at_the_fallback_dir_is_refused(self):
        self.cache.mkdir()
        self.app_dir.write_text("")
        self.assert_refused(*self.run_snapshot(XDG_RUNTIME_DIR=""))

    def test_a_symlink_at_the_lock_file_is_refused_and_its_target_never_created_or_changed(self):
        dangling, existing = self.victim / "planted.lock", self.victim / "existing"
        existing.write_text("")
        existing.chmod(0o644)
        self.runtime_lock.symlink_to(dangling)  # plain O_CREAT would create this for them
        self.assert_refused(*self.run_snapshot())
        self.runtime_lock.unlink()
        self.runtime_lock.symlink_to(existing)
        self.assert_refused(*self.run_snapshot())
        override = self.root / "override.lock"  # AEGIS_LOCK gets the same file checks
        override.symlink_to(dangling)
        self.assert_refused(*self.run_snapshot(AEGIS_LOCK=str(override)))
        self.assertFalse(dangling.exists())
        self.assertEqual(self.mode(existing), 0o644)

    def test_a_lock_path_that_is_not_a_regular_file_is_refused(self):
        os.mkfifo(self.runtime_lock)
        self.assert_refused(*self.run_snapshot())
        os.unlink(self.runtime_lock)
        self.runtime_lock.mkdir()
        self.assert_refused(*self.run_snapshot(), what="cannot open lock file")

    def test_a_lock_file_owned_by_someone_else_is_refused(self):
        lock, log = self.root / "cli.lock", self.root / "argv.log"
        lock.write_text("")
        env = {"AEGIS_CLI": str(FAKE), "AEGIS_LOCK": str(lock), "FAKE_MODE": "disconnected", "FAKE_LOG": str(log)}
        with mock.patch.dict(os.environ, env), \
                mock.patch.object(agvpn.os, "getuid", return_value=os.getuid() + 1):
            with self.assertRaises(agvpn.CliError) as ctx:
                agvpn.run_cli(["status"])
        self.assertEqual(ctx.exception.code, "unknown")
        self.assertIn("untrusted lock path", ctx.exception.message)
        self.assertFalse(log.exists())

    def test_a_new_lock_file_is_0600_and_an_existing_0644_one_is_narrowed(self):
        j, ran = self.run_snapshot()
        self.assertTrue(j["ok"] and ran, j)
        self.assertEqual(self.mode(self.runtime_lock), 0o600)
        self.runtime_lock.chmod(0o644)  # what older versions left behind
        j, ran = self.run_snapshot()
        self.assertTrue(j["ok"] and ran, j)
        self.assertEqual(self.mode(self.runtime_lock), 0o600)
        j, ran = self.run_snapshot(XDG_RUNTIME_DIR="")
        self.assertTrue(j["ok"] and ran, j)
        self.assertEqual(self.mode(self.fallback_lock), 0o600)

    def test_a_filesystem_without_record_locks_still_runs_unlocked(self):
        env = {"AEGIS_CLI": str(FAKE), "AEGIS_LOCK": str(self.root / "cli.lock"), "FAKE_MODE": "disconnected"}
        with mock.patch.dict(os.environ, env), \
                mock.patch.object(agvpn.fcntl, "lockf", side_effect=OSError(errno.ENOLCK, "No locks available")):
            rc, out, _ = agvpn.run_cli(["status"])
        self.assertEqual(rc, 0)
        self.assertEqual(agvpn.parse_status(out)["state"], "disconnected")

    # ---------------------------------------------------------- home.json --

    def run_home(self, mode="disconnected"):
        curl = self.root / "curl"
        if not curl.exists():
            curl.write_text(self.CURL)
            curl.chmod(0o755)
        rc, out, _ = run_verb("home", mode=mode, env_extra=dict(self.env, AEGIS_CURL=str(curl)))
        return json.loads(out)

    def planted(self, city):
        return json.dumps({"lat": 1.5, "lon": 2.5, "city": city, "iso": "XX", "gateway": "gw", "fetchedAt": 0})

    def test_home_json_is_written_0600_in_a_0700_dir_with_no_temp_file_left(self):
        j = self.run_home()
        self.assertTrue(j["ok"], j)
        self.assertEqual(j["home"]["city"], "Haifa")
        home = self.app_dir / "home.json"
        self.assertEqual(self.mode(self.app_dir), 0o700)
        self.assertEqual(self.mode(home), 0o600)
        self.assertEqual(json.loads(home.read_text())["city"], "Haifa")
        self.assertEqual([p.name for p in self.app_dir.iterdir()], ["home.json"])

    def test_an_existing_readable_cache_ends_up_private_after_a_fetch(self):
        self.app_dir.mkdir(parents=True)
        self.app_dir.chmod(0o755)
        home = self.app_dir / "home.json"
        home.write_text(self.planted("Old"))  # fetchedAt 0: due for a refresh
        home.chmod(0o644)
        j = self.run_home()
        self.assertEqual(j["home"]["city"], "Haifa")
        self.assertEqual(self.mode(self.app_dir), 0o700)
        self.assertEqual(self.mode(home), 0o600)
        self.assertEqual(json.loads(home.read_text())["city"], "Haifa")

    def test_a_symlinked_home_json_is_neither_read_nor_written_through(self):
        self.app_dir.mkdir(parents=True)
        elsewhere = self.victim / "elsewhere.json"
        elsewhere.write_text(self.planted("Planted"))
        before = elsewhere.read_text()
        home = self.app_dir / "home.json"
        home.symlink_to(elsewhere)
        j = self.run_home(mode="connected")  # no lookup while connected: the cache is the only source
        self.assertTrue(j["ok"], j)
        self.assertIsNone(j["home"])
        j = self.run_home()
        self.assertEqual(j["home"]["city"], "Haifa")
        self.assertFalse(home.is_symlink(), "the fetch replaces the link itself")
        self.assertEqual(self.mode(home), 0o600)
        self.assertEqual(elsewhere.read_text(), before)

    def test_a_symlinked_cache_dir_is_no_cache_and_never_written_to(self):
        self.cache.mkdir()
        planted = self.victim / "home.json"
        planted.write_text(self.planted("Planted"))
        before = planted.read_text()
        self.app_dir.symlink_to(self.victim)
        j = self.run_home(mode="connected")
        self.assertIsNone(j["home"])
        j = self.run_home()
        self.assertTrue(j["ok"], j)
        self.assertEqual(j["home"]["city"], "Haifa", "the lookup's answer stands without a cache")
        self.assertEqual([p.name for p in self.victim.iterdir()], ["home.json"])
        self.assertEqual(planted.read_text(), before)

    def test_a_failed_cache_write_removes_its_temp_file(self):
        d = self.root / "d"
        d.mkdir()
        (d / "home.json").mkdir()  # renaming a file over a directory fails
        self.assertFalse(agvpn.write_private_json(d / "home.json", {"city": "Haifa"}))
        self.assertEqual([p.name for p in d.iterdir()], ["home.json"])


if __name__ == "__main__":
    unittest.main()
