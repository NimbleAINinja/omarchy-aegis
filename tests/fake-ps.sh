#!/usr/bin/env bash
# Fake ps for tests: "pid comm" lines with duplicates, kernel threads, padding,
# shells, and the helper's own interpreter. Logs argv. FAKE_PS_FAIL=1 → exit 1.
# pid 42 has a fake /proc entry (see AEGIS_PROC in the tests) whose exe is
# /usr/bin/transmission-gtk while comm is the kernel-truncated form.
[[ -n ${FAKE_LOG:-} ]] && printf 'ps %s\n' "$*" >> "$FAKE_LOG"
[[ -n ${FAKE_PS_FAIL:-} ]] && exit 1
cat <<'LIST'
   11 firefox
   42 transmission-gt
   13 kworker/0:1
   14 firefox
   15 bash
   16 python3
   17 Hyprland
   18 quickshell
   19 zsh
   20 ps
   21 Signal
   22 foot
   23 foot
   25 irq/44:pciehp
   26 
   27 nvim
   28 dbus-broker-lau
LIST
exit 0
