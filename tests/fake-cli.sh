#!/usr/bin/env bash
# Stand-in for adguardvpn-cli driven by $FAKE_MODE; prints fixtures verbatim.
#   FAKE_MODE=connected|disconnected|connecting|login|sudo|hang|slow|linger|excl2|selective|socks|newversion|updatefail|notty
# Every invocation is appended to $FAKE_LOG when set, so tests can assert argv.
# $FAKE_FDS, when set, receives where this process's stdout and stderr point.
fixtures="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures"
mode="${FAKE_MODE:-connected}"
[[ $mode == socksconnected ]] && { if [[ ${1:-} == status ]]; then cat "$(dirname "$0")/fixtures/status_connected_socks.txt"; exit 0; fi; mode=connected; }
[[ -n ${FAKE_LOG:-} ]] && printf '%s\n' "$*" >> "$FAKE_LOG"
if [[ -n ${FAKE_FDS:-} ]]; then
  fd1=$(readlink /proc/$$/fd/1); fd2=$(readlink /proc/$$/fd/2)
  printf '%s\n%s\n' "$fd1" "$fd2" > "$FAKE_FDS"
fi
if [[ $mode == hang ]]; then exec sleep 30; fi
# linger: a long call. Writes $$ to $FAKE_PIDFILE, sleeps $FAKE_SLEEP (default
# 30) where SIGTERM ends it (FAKE_IGNORE_TERM=1: ignored), then writes a long
# fixture to stdout and logs "end <time> <rc of that write>" — 141 when stdout
# was a pipe nobody reads any more (SIGPIPE).
if [[ $mode == linger ]]; then
  if [[ ${FAKE_IGNORE_TERM:-} == 1 ]]; then trap '' TERM; else trap 'kill "$child" 2>/dev/null; exit 143' TERM; fi
  [[ -n ${FAKE_PIDFILE:-} ]] && echo $$ > "$FAKE_PIDFILE"
  [[ -n ${FAKE_LOG:-} ]] && printf 'start %s\n' "$(date +%s.%N)" >> "$FAKE_LOG"
  sleep "${FAKE_SLEEP:-30}" & child=$!
  wait "$child"
  cat "$fixtures/list_locations.txt"; rc=$?
  [[ -n ${FAKE_LOG:-} ]] && printf 'end %s %s\n' "$(date +%s.%N)" "$rc" >> "$FAKE_LOG"
  exit 0
fi
if [[ $mode == slow ]]; then
  [[ -n ${FAKE_LOG:-} ]] && printf 'start %s\n' "$(date +%s.%N)" >> "$FAKE_LOG"
  sleep 0.6
  [[ -n ${FAKE_LOG:-} ]] && printf 'end %s\n' "$(date +%s.%N)" >> "$FAKE_LOG"
  mode=disconnected
fi
case "$1" in
  status)
    case "$mode" in
      disconnected|sudo) cat "$fixtures/status_disconnected.txt" ;;
      connecting) cat "$fixtures/status_connecting.txt" ;;
      login) cat "$fixtures/status_login.txt" ;;
      *) cat "$fixtures/status_connected.txt" ;;
    esac ;;
  list-locations) cat "$fixtures/list_locations.txt" ;;
  license)
    if [[ $mode == login ]]; then cat "$fixtures/license_logged_out.txt"; exit 1; fi
    cat "$fixtures/license.txt" ;;
  connect)
    if [[ $mode == sudo ]]; then cat "$fixtures/sudo_error.txt" >&2; exit 1; fi
    if [[ $mode == login ]]; then cat "$fixtures/status_login.txt"; exit 1; fi
    cat "$fixtures/connect_ok.txt" ;;
  disconnect) cat "$fixtures/disconnect_ok.txt" ;;
  logout) echo "Logged out" ;;
  site-exclusions)
    case "$2" in
      show) if [[ $mode == excl2 || $mode == selective ]]; then cat "$fixtures/exclusions_show_two.txt"; else cat "$fixtures/exclusions_show_empty.txt"; fi ;;
      mode) if [[ $mode == selective ]]; then cat "$fixtures/exclusions_mode_selective.txt"; else cat "$fixtures/exclusions_mode.txt"; fi ;;
      add|remove|clear) echo "ok" ;;
      *) echo "unknown" >&2; exit 106 ;;
    esac ;;
  config)
    case "$2" in
      show) if [[ $mode == socks ]]; then cat "$fixtures/config_show_socks.txt"; else cat "$fixtures/config_show.txt"; fi ;;
      set-mode|set-dns|set-socks-port|set-socks-host|set-socks-username|clear-socks-auth|set-change-system-dns|set-protocol|set-post-quantum) echo "ok" ;;
      set-socks-password)
        # Like adguardvpn-cli 1.7.12: with no positional it reads the password
        # from stdin; with nothing there (or FAKE_MODE=notty) it can't prompt,
        # keeps the old value and exits 16. $FAKE_STDIN receives the line read.
        if [[ $# -ge 3 ]]; then echo "ok"; exit 0; fi
        IFS= read -r line; got=$?
        [[ -n ${FAKE_STDIN:-} ]] && printf '%s' "$line" > "$FAKE_STDIN"
        if [[ $mode == notty ]] || [[ $got -ne 0 && -z $line ]]; then
          printf '%s\n' 'Enter password for accessing SOCKS5 server: ' \
            'Warning: No TTY for user input. Using default value (no). Use `adguardvpn-cli config set-socks-password <password>` to change.'
          exit 16
        fi
        echo "Config has been updated" ;;
      *) echo "unknown config subcommand" >&2; exit 106 ;;
    esac ;;
  check-update)
    # The real CLI exits 17 even when up to date.
    if [[ $mode == newversion ]]; then cat "$fixtures/check_update_new.txt"; exit 0; fi
    if [[ $mode == updatefail ]]; then cat "$fixtures/check_update_failed.txt" >&2; exit 1; fi
    cat "$fixtures/check_update_latest.txt"; exit 17 ;;
  --version|-v) echo "AdGuard VPN CLI v1.7.12" ;;
  *) echo "The following argument was not expected: $1" >&2; exit 106 ;;
esac
