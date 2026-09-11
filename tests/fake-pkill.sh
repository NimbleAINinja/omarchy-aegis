#!/usr/bin/env bash
# Fake pkill for tests: "sleepy" exists, everything else does not. Logs argv.
[[ -n ${FAKE_LOG:-} ]] && printf 'pkill %s\n' "$*" >> "$FAKE_LOG"
last="${@: -1}"
[[ $last == sleepy ]] && exit 0
exit 1
