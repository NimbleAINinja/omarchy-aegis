#!/usr/bin/env python3
"""Tests for agvpn.py: pure parsers against recorded fixtures, then every verb
end to end through tests/fake-cli.sh. Run from the plugin root:
    python3 -m unittest tests/agvpn_test.py
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIX = ROOT / "tests" / "fixtures"
FAKE = ROOT / "tests" / "fake-cli.sh"
HELPER = ROOT / "agvpn.py"

spec = importlib.util.spec_from_file_location("agvpn", HELPER)
agvpn = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agvpn)


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
        self.assertIn("pkill -x -- sleepy", argv)
        self.assertNotIn("-f", argv)
        self.assertNotIn("bad name", argv)

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


if __name__ == "__main__":
    unittest.main()
