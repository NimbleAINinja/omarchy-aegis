# Aegis

AdGuard VPN, living in your Omarchy bar. Open the panel, see where your
traffic leaves the world on a dot-matrix map, pick a city, and you're
connected. No terminal, no separate app.

![Aegis panel](preview.png)

## Highlights

- **Connect in one click.** Locations sorted by ping, favourites pinned at the
  top, a search that starts the moment you type.
- **See your tunnel.** An arc runs from your location to the exit city. It
  dashes while connecting and carries traffic beads once you're through.
- **Find the fast exits at a glance.** Each city's map dot is tinted by its
  ping, so the green ones are the ones to pick. Hover a city and click to go.
- **Watch your throughput.** A traffic tab draws the last couple of minutes
  as a dot-matrix graph, sent above the line, received below.
- **Flip a switch.** The hero toggle turns the VPN off, or back on to your last
  location. Right-click the bar icon to do the same without opening the panel.
- **Stays on across reboots.** If the VPN was on when your session ended,
  crash or not, it reconnects at login.
- **Kill switch.** Pick the apps that should never run unprotected and Aegis
  closes them within seconds of a drop, then tells you. It closes apps, it
  doesn't block traffic ([details](#kill-switch)).
- **Exclusions and account in the same panel.** Add sites that bypass the
  tunnel, pause and resume them without retyping, log in and out.
- **Every setting the CLI has.** TUN or SOCKS, protocol, post-quantum, DNS,
  and a one-click CLI update when one is available.
- **Your bar, your way.** Icon, country code, or live down/up rates.
- **Entirely keyboard driven.** Every action has a key, and `Esc` always
  closes.
- **Sets itself up.** No CLI, not signed in, or sudo asking for a password:
  the panel says which, and one button fixes it.

## Install

```bash
omarchy plugin add https://github.com/NimbleAINinja/omarchy-aegis.git --enable
```

Or by hand: copy this folder to `~/.config/omarchy/plugins/io.github.nimbleaininja.aegis/`,
then `omarchy plugin enable io.github.nimbleaininja.aegis --section right`.

## Requirements

`python3` (standard library only), `curl`, and three things the panel checks
for you. Whichever is missing first shows up under the hero with a button,
and all three have a row under Settings › Setup:

- `adguardvpn-cli`, the official AdGuard VPN CLI. **Install** opens a
  terminal running AdGuard's own installer.
- An AdGuard VPN account. **Log in** opens a terminal running
  `adguardvpn-cli login`.
- A sudoers rule, so the CLI can start its VPN service without a password
  prompt (needs sudo 1.9.10 or newer). **Set up** writes it after a polkit
  prompt. What it writes is the rule below (`aegis-sudo-rule` in this
  folder, checked with `visudo -cf` before it is installed), which allows
  exactly the one command the CLI runs as root to connect, for any location,
  and nothing else. To install it by hand instead, keep it on one line and
  replace every `youruser` and the `1000` with your user name and `id -u`:

  ```
  # /etc/sudoers.d/adguardvpn-cli  (mode 0440, check with: visudo -cf <file>)
  youruser ALL=(root) NOPASSWD: /usr/bin/env ^HOME=/home/youruser XDG_DATA_HOME=/home/youruser/\.local/share DISPLAY=:[0-9]+(\.[0-9]+)? DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus /opt/adguardvpn_cli/adguardvpn-cli connect --no-fork -l [^-[:space:]][^[:space:]]*( [^-[:space:]][^[:space:]]*)* (-v )?--log-to-file --wait-for-parent --ppid-file /home/youruser/\.local/share/adguardvpn-cli/vpn\.pid$
  ```

  The panel probes the rule with `sudo -l` (no password, nothing run) and
  says so when it is missing; SOCKS mode never needs it.

## Keyboard

| Key | Action |
|---|---|
| `j` / `k`, arrows | move the cursor |
| `Enter` / `Space` | connect to the row, or flip the switch |
| any letter, `/` | search locations |
| `f` | favourite the row under the cursor |
| `t` | toggle the VPN |
| `d` | disconnect |
| `r` | refresh |
| `e` / `a` / `s` | exclusions, account, settings |
| `Shift+K` / `Shift+T` / `Shift+L` | kill switch, traffic, back to locations |
| `h` / `l` | switch chips (mode, protocol) in settings |
| `p` / `x` | pause or remove the exclusion under the cursor |
| `Tab` (kill-switch field) | add the highlighted running app |
| `Esc` | close the panel (in the search field: clear it) |
| `Tab` | next bar panel |

Bar icon: left click opens the panel, right click toggles the VPN, middle
click refreshes.

## Shell IPC

```bash
omarchy-shell io.github.nimbleaininja.aegis toggle          # open / close the panel
omarchy-shell io.github.nimbleaininja.aegis connect "Tokyo"  # any city from the list
omarchy-shell io.github.nimbleaininja.aegis up               # reconnect to the last location
omarchy-shell io.github.nimbleaininja.aegis down
omarchy-shell io.github.nimbleaininja.aegis toggleVpn
omarchy-shell io.github.nimbleaininja.aegis refresh
omarchy-shell io.github.nimbleaininja.aegis status           # JSON
omarchy-shell io.github.nimbleaininja.aegis barMode rate     # icon | iso | rate
omarchy-shell io.github.nimbleaininja.aegis view traffic     # list | exclusions | account | settings | killswitch | traffic
```

## Configure

Most of this is set from the panel itself. The keys live on the
widget's entry in `~/.config/omarchy/shell.json`:

```json
{ "id": "io.github.nimbleaininja.aegis", "barMode": "icon", "refreshIntervalSec": 30,
  "favorites": ["US|New York"], "lastLocation": "New York" }
```

| Key | Default | Meaning |
|---|---|---|
| `barMode` | `icon` | `icon`, `iso` (country code), or `rate` (live down/up). Vertical bars always show the icon |
| `refreshIntervalSec` | `30` | status poll while the panel is open. Closed, the poll backs off and the CLI's tunnel log is watched instead, so a drop is still noticed within seconds |
| `favorites` | `[]` | `ISO|City` keys, managed with `f` or the star |
| `lastLocation` | `""` | what the switch reconnects to |
| `autoConnect` | `true` | reconnect at login if the VPN was on when the last session ended |
| `killSwitch` | `false` | close `killApps` a few seconds after the tunnel drops unexpectedly, see [Kill switch](#kill-switch) |
| `killOnDisconnect` | `false` | also close `killApps` when you disconnect or log out yourself |
| `killApps` | `""` | comma separated process names, picked from the running apps the panel suggests |
| `locateHome` | `true` | look up your location once, while the VPN is off, to place the home marker; off uses a time-zone estimate, see [Privacy](#privacy) |
| `pingDots` | `true` | tint each city's map dot by its ping tier |

Connection settings (mode, protocol, post-quantum, DNS, SOCKS) are read from
and written to the CLI's own config, so they stay in step with the CLI
wherever you change them. They apply on the next connect. The SOCKS
password is handed to the CLI on stdin, never on a command line.

## Kill switch

The kill switch closes apps; it is not a firewall. While the VPN is up,
Aegis watches the CLI's tunnel log. When the tunnel goes down and is still
down a few seconds later (a location switch or a brief network hiccup
recovers on its own and doesn't count), it confirms with the CLI and closes
the listed apps, scoped to your own processes. That usually takes five to
ten seconds, during which the apps can keep talking over your normal
connection, and nothing stops an app you start again afterwards. If the VPN
daemon dies without logging anything, the drop is caught at the next status
poll instead. A drop while the shell isn't running isn't caught at all.

## Privacy

Everything runs locally against `adguardvpn-cli`. The only request the
plugin itself makes is one lookup to `https://ipinfo.io/json` to place your
home marker on the map. It sends your public IP and gets back an
approximate city.

That lookup runs only while the VPN is off because you turned it off: never
at login before auto-connect has had its chance, and never after an
unexpected drop. The result is cached in
`~/.cache/io.github.nimbleaininja.aegis/home.json`, readable only by you,
and refreshed only when your default gateway changes or after 24 hours.

Turn off "Locate home" in settings and no lookup ever runs: the cached
location is deleted and the marker falls back to a rough position from your
time zone.

## Development

```bash
tests/run                    # manifest, python helper, node models, headless QML, lint
omarchy plugin validate .
```

`agvpn.py` wraps the CLI and prints one JSON document per call; set
`AEGIS_CLI` to point it at a fake CLI. `Model.js` and `Link.js` are pure
ES5 shared by QML and the node tests.

Map data: see `assets/NOTICE.md`.

## License

MIT
