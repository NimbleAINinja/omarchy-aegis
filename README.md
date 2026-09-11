# Aegis

AdGuard VPN in the Omarchy bar. A dot-matrix world map shows where your
traffic exits, with a live arc from your location to the exit city. Pick a
location, it connects. That is the whole interface.

![Aegis panel](preview.png)

## Highlights

- One-click locations, sorted by ping, with favorites pinned at the top
- Map with an animated link from your real location to the exit city
- Hero switch turns the VPN off, or back on to your last location
- Bar icon lights up when connected; optional country code or live rates
- Site exclusions (general or selective) and account state in the same panel
- Settings: TUN or SOCKS mode (with host, port and auth), protocol, post-quantum,
  DNS upstream and system DNS, all through the CLI's own config
- Reconnects at login if the VPN was on when the session ended, crashes included
- Kill switch: closes the apps you pick (suggested from what is running) within seconds of a drop, and tells you;
  optionally also when you disconnect or log out yourself. It closes apps, it doesn't block traffic ([details](#kill-switch))
- Exclusions can be paused and resumed without retyping them
- Hover the map: the nearest city lights up with its name, click to connect
- The row under your cursor rings its city on the map
- Kill switch has its own tab (skull in the footer, filled and lit while armed)
- Daily CLI update check with a one-click update
- Fully keyboard driven

## Install

```bash
omarchy plugin add https://github.com/NimbleAINinja/omarchy-aegis.git --enable
```

Or by hand: copy this folder to `~/.config/omarchy/plugins/io.github.nimbleaininja.aegis/`,
then `omarchy plugin enable io.github.nimbleaininja.aegis --section right`.

## Requirements

- `adguardvpn-cli` (the official AdGuard VPN CLI), logged in
- A sudoers rule so the CLI can start its VPN service without a password prompt (sudo 1.9.10 or newer).
  To connect, the CLI runs one command as root:
  `sudo -b env HOME=… XDG_DATA_HOME=… DISPLAY=… DBUS_SESSION_BUS_ADDRESS=… /opt/adguardvpn_cli/adguardvpn-cli connect --no-fork -l <location> … --ppid-file …/vpn.pid`.
  The rule below allows exactly that, for any location, and nothing else. Its arguments are a regular
  expression, so keep it on one line; replace every `youruser` and the `1000` with your user name and `id -u`:

  ```
  # /etc/sudoers.d/adguardvpn-cli  (mode 0440, check with: visudo -cf <file>)
  youruser ALL=(root) NOPASSWD: /usr/bin/env ^HOME=/home/youruser XDG_DATA_HOME=/home/youruser/\.local/share DISPLAY=:[0-9]+(\.[0-9]+)? DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus /opt/adguardvpn_cli/adguardvpn-cli connect --no-fork -l [^-[:space:]][^[:space:]]*( [^-[:space:]][^[:space:]]*)* (-v )?--log-to-file --wait-for-parent --ppid-file /home/youruser/\.local/share/adguardvpn-cli/vpn\.pid$
  ```

  If you installed the earlier rule ending in `adguardvpn-cli *`, replace it: it let any program running
  as you run every CLI subcommand as root, e.g. `export-logs -o <path> -f` to overwrite any file.
  Two rarely used paths aren't covered and will ask for a password: the CLI's `sudo kill` fallback when
  the service won't stop, and `config create-route-script`.
  What remains: the root VPN service runs with your `HOME` and `XDG_DATA_HOME`, uses the settings in your
  data directory and writes its log, pid file and socket there, and any program running as you can still
  start it without a password.

  When the rule is missing or broken the panel shows “sudo needs a password”.
- `python3` (standard library only), `curl` for the one-time location lookup

## Keyboard

| Key | Action |
|---|---|
| `j` / `k`, arrows | move the cursor |
| `Enter` / `Space` | connect to the row, or flip the switch |
| any letter, `/` | search locations |
| `f` | favorite the row under the cursor |
| `t` | toggle the VPN |
| `d` | disconnect |
| `e` | exclusions |
| `a` | account |
| `s` | settings |
| `K` (Shift+k) | kill switch tab (plain `k` is cursor-up) |
| `h` / `l` | switch chips (mode, protocol) in settings |
| `p` | pause or resume the exclusion under the cursor |
| `x` | remove the exclusion under the cursor |
| `Tab` (in the kill-switch field) | add the highlighted running app |
| `Enter` (in the kill-switch field) | add exactly what you typed, or the highlighted app if you've arrowed to one |
| `r` | refresh |
| `Esc` | back, then close |
| `Tab` | next bar panel |

Bar icon: left click opens the panel, right click toggles the VPN, middle click refreshes.

## Shell IPC

```bash
omarchy-shell io.github.nimbleaininja.aegis toggle          # open / close the panel
omarchy-shell io.github.nimbleaininja.aegis connect "Tokyo"  # any city from the list
omarchy-shell io.github.nimbleaininja.aegis down
omarchy-shell io.github.nimbleaininja.aegis toggleVpn
omarchy-shell io.github.nimbleaininja.aegis status           # JSON
omarchy-shell io.github.nimbleaininja.aegis barMode rate     # icon | iso | rate
omarchy-shell io.github.nimbleaininja.aegis view exclusions  # list | exclusions | account | settings | killswitch
```

## Configure

Settings live inline on the widget's entry in `~/.config/omarchy/shell.json`:

```json
{ "id": "io.github.nimbleaininja.aegis", "barMode": "icon", "refreshIntervalSec": 30,
  "favorites": ["US|New York"], "lastLocation": "New York" }
```

| Key | Default | Meaning |
|---|---|---|
| `barMode` | `icon` | `icon`, `iso` (country code), or `rate` (live down/up). Vertical bars always show the icon |
| `refreshIntervalSec` | `30` | status poll while the panel is open (doubled while closed); while connected, a state change in the CLI's `tunnel.log` also triggers a check within seconds |
| `favorites` | `[]` | `ISO|City` keys, managed with `f` or the star |
| `lastLocation` | `""` | what the switch reconnects to |
| `autoConnect` | `true` | reconnect at login when `wasConnected` is still set |
| `wasConnected` | internal | set while connected, cleared only by a disconnect or logout you make; survives crashes and reboots |
| `killSwitch` | `false` | close `killApps` a few seconds after the tunnel drops unexpectedly (critical notification); closes apps, doesn't block traffic, see [Kill switch](#kill-switch) |
| `killOnDisconnect` | `false` | with `killSwitch` on, also close `killApps` once a disconnect or logout you make has gone through (normal notification); off, your own disconnects close nothing and send no alert |
| `killApps` | `""` | comma separated process names, each killed with `pkill -u <your uid> -x`; pick them from the suggestions of running processes |
| `pausedExclusions` | internal | `{general: [], selective: []}` domains you paused; they are removed from the CLI list and re-added on resume |
| `lastUpdateCheck` | internal | epoch seconds of the last `check-update`; checked again after 24 h |
| `locateHome` | `true` | look up your location from `ipinfo.io` while the VPN is off, to place the home marker on the map; off deletes the cached location and falls back to a time-zone estimate |

Connection settings (mode, protocol, post-quantum, DNS, SOCKS) are not stored
by Aegis: they are read from and written to the CLI with `adguardvpn-cli config`.
Changes to mode, protocol, post-quantum or DNS apply on the next connect.
The SOCKS password is handed to the CLI on stdin, never on a command line,
so it never shows up in `ps` for other local users.

## Kill switch

The kill switch closes apps; it is not a firewall. While the VPN is up, Aegis
watches the CLI's `tunnel.log` for state changes. When the tunnel goes down
and hasn't come back a few seconds later (a location switch or a brief
network recovery comes back on its own and is not a drop), it confirms with
`adguardvpn-cli status` and closes the listed apps with `pkill -u <your uid>
-x`, scoped to your own processes so a same-named process belonging to
another user on the system is never touched. That usually takes five to ten
seconds, longer if another CLI call is still running. Until then the apps
can keep sending over your normal connection,
and nothing stops an app you start again afterwards. If the VPN daemon dies
without logging anything, the drop is only caught at the next status poll
(`refreshIntervalSec`, doubled while the panel is closed). A drop while the
shell isn't running, or before you log in, isn't caught at all.

## Privacy

Everything runs locally against `adguardvpn-cli`. The only outbound request the
plugin itself makes is one lookup to `https://ipinfo.io/json`, which sends
your public IP address (and gets back an approximate city/coordinates in
return) to place your home marker.

That lookup only ever runs while the VPN is off because you turned it off:
never at login before startup has settled and auto-connect has had its
chance to reconnect a VPN that was on last session, and never right after
the tunnel drops unexpectedly — a hold that lasts until you connect,
disconnect, or toggle the VPN yourself, not just for one status check. It
also stays held for as long as you last asked the VPN to be on (even across
a failed reconnect, or a drop, where the CLI itself already reads
"disconnected"): only a disconnect or logout you make yourself clears that
intent, and only then can a lookup run — that's the clear net you chose. The
result is cached in `~/.cache/io.github.nimbleaininja.aegis/home.json` (a
0600 file in a 0700 directory, readable only by you) and refreshed only when
your default gateway changes or after 24 hours.

Turn it off with the "Locate home" setting: no lookup ever runs, the cached
location is deleted immediately, and the marker falls back to a rough
position derived from your time zone (also the fallback until the first
lookup succeeds, with the setting on).

## Development

```bash
tests/run                    # manifest, python helper, node models, headless QML, lint
omarchy plugin validate .
```

`agvpn.py` wraps the CLI and prints one JSON document per call (`snapshot`,
`locations`, `connect <name>`, `disconnect`, `account`, `logout`,
`exclusions …`, `config show|set <key> <value>`, `update-check`, `kill <name…>`,
`home`, `home cached`, `home forget`). `home cached` reads only the cached
location — no CLI call, no network, any VPN state — so the panel can show a
last-known location immediately; `home forget` just deletes the cached
home.json — no CLI call, no network — for turning the "Locate home" setting
off. The SOCKS
password is the one exception to `set <key> <value>`:
`config set socksPassword -` reads it as a single line on stdin, and a value
passed on the command line is refused. `Model.js` and `Link.js` are pure ES5 shared by QML
and the node tests. Set `AEGIS_CLI` to point the helper at a fake CLI.

Map data: see `assets/NOTICE.md`.

## License

MIT
