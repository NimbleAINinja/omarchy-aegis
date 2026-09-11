#!/usr/bin/env bash
# Stand-in for adguardvpn-cli driven by $FAKE_MODE; prints fixtures verbatim.
#   FAKE_MODE=connected|disconnected|connecting|login|sudo|hang|excl2|selective|socks|newversion
# Every invocation is appended to $FAKE_LOG when set, so tests can assert argv.
fixtures="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures"
mode="${FAKE_MODE:-connected}"
[[ $mode == socksconnected ]] && { if [[ ${1:-} == status ]]; then cat "$(dirname "$0")/fixtures/status_connected_socks.txt"; exit 0; fi; mode=connected; }
[[ -n ${FAKE_LOG:-} ]] && printf '%s\n' "$*" >> "$FAKE_LOG"
if [[ $mode == hang ]]; then sleep 30; exit 0; fi
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
      set-mode|set-dns|set-socks-port|set-socks-host|set-socks-username|set-socks-password|clear-socks-auth|set-change-system-dns|set-protocol|set-post-quantum) echo "ok" ;;
      *) echo "unknown config subcommand" >&2; exit 106 ;;
    esac ;;
  check-update)
    # The real CLI exits 17 even when up to date.
    if [[ $mode == newversion ]]; then cat "$fixtures/check_update_new.txt"; exit 0; fi
    cat "$fixtures/check_update_latest.txt"; exit 17 ;;
  --version|-v) echo "AdGuard VPN CLI v1.7.12" ;;
  *) echo "The following argument was not expected: $1" >&2; exit 106 ;;
esac
