#!/bin/sh
# Stand-in for sudo in tests: records its argv, one per line, in $FAKE_LOG
# and exits $FAKE_SUDO_RC (0 = the command is allowed without a password).
for a in "$@"; do printf '%s\n' "$a"; done > "${FAKE_LOG:?}"
# $FAKE_SUDO_LIST stands in for what `sudo -l` prints about this user.
printf '%s' "${FAKE_SUDO_LIST:-}"
exit "${FAKE_SUDO_RC:-0}"
