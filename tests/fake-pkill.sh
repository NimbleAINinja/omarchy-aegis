#!/usr/bin/env bash
# Fake pkill for tests: "sleepy" exists, everything else does not. Logs argv.
# verb_kill now calls this as `pkill -u <uid> -x -- <name>`; the name is
# still the last word, so matching on it alone is unaffected by that prefix.
[[ -n ${FAKE_LOG:-} ]] && printf 'pkill %s\n' "$*" >> "$FAKE_LOG"
last="${@: -1}"
[[ $last == sleepy ]] && exit 0
exit 1
