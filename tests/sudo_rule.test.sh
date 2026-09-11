#!/usr/bin/env bash
# aegis-sudo-rule writes the rule README.md documents, filled in for one
# user: the two must never drift apart, a home directory with regex
# operators in it must still be matched literally, and the install path
# must leave exactly one 0440 file behind, or nothing.
set -euo pipefail
dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script=$dir/aegis-sudo-rule
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "sudo_rule: $*" >&2; exit 1; }

[[ -x $script ]] || fail "aegis-sudo-rule is not executable"

# --- the README's rule, byte for byte
readme=$(grep -E '^[[:space:]]*youruser ALL=' "$dir/README.md" | sed 's/^[[:space:]]*//')
printed=$(AEGIS_PASSWD='youruser:x:1000:1000::/home/youruser:/bin/sh' sh "$script" --print 1000)
[[ $printed == "$readme" ]] || { echo "sudo_rule: --print differs from README.md:" >&2; diff <(echo "$readme") <(echo "$printed") >&2 || true; exit 1; }

# --print with no uid falls back to the caller; PKEXEC_UID wins over that
me=$(AEGIS_PASSWD="$(id -un):x:$(id -u):$(id -g)::$HOME:/bin/sh" sh "$script" --print)
[[ $me == "$(id -un) ALL=(root) NOPASSWD: /usr/bin/env ^HOME="* ]] || fail "--print without a uid should use the caller"
via_pkexec=$(PKEXEC_UID=1000 AEGIS_PASSWD='youruser:x:1000:1000::/home/youruser:/bin/sh' sh "$script" --print)
[[ $via_pkexec == "$readme" ]] || fail "PKEXEC_UID should select the user"

# --- regex operators in the home directory are escaped, and the result
# still passes the README rule's own matcher for that user
AEGIS_PASSWD='a.b:x:1234:1234::/home/a.b:/bin/sh' sh "$script" --print 1234 > "$tmp/dotted"
grep -qF 'HOME=/home/a\.b XDG_DATA_HOME=/home/a\.b/\.local/share' "$tmp/dotted" || fail "dots in the home directory must be escaped"
grep -qF '/run/user/1234/bus' "$tmp/dotted" || fail "the uid must reach the bus path"
bash "$dir/tests/sudoers.test.sh" "$tmp/dotted" a.b 1234 > /dev/null || fail "the filled-in rule fails the README matcher"

# --- refusals: nothing is printed, nothing is written
refuse() {
  local what=$1
  shift
  if "$@" > "$tmp/out" 2> "$tmp/err"; then fail "should refuse: $what"; fi
  [[ ! -s $tmp/out ]] || fail "refusing $what must print nothing"
  grep -q 'aegis-sudo-rule:' "$tmp/err" || fail "refusing $what must say why"
}
refuse "a non-numeric uid" env AEGIS_PASSWD='x:x:1:1::/home/x:/bin/sh' sh "$script" --print abc
refuse "an unknown uid" env -u AEGIS_PASSWD sh "$script" --print 4000000000
refuse "a user name sudoers could misread" env AEGIS_PASSWD='bad name:x:1:1::/home/bad:/bin/sh' sh "$script" --print 1
refuse "a home directory with whitespace" env AEGIS_PASSWD='bad:x:1:1::/home/bad guy:/bin/sh' sh "$script" --print 1
refuse "a relative home directory" env AEGIS_PASSWD='bad:x:1:1::home/bad:/bin/sh' sh "$script" --print 1
refuse "installing with no user at all" env -u PKEXEC_UID AEGIS_SUDOERS_DIR="$tmp" AEGIS_PASSWD='x:x:1:1::/home/x:/bin/sh' sh "$script"
if (( EUID != 0 )); then
  refuse "installing unprivileged" env -u AEGIS_SUDOERS_DIR AEGIS_PASSWD='x:x:1:1::/home/x:/bin/sh' sh "$script" 1
fi

# --- install: one 0440 file, the printed rule inside, no temp file left
if command -v visudo >/dev/null 2>&1 && printf 'nobody ALL=(root) NOPASSWD: /usr/bin/true\n' > "$tmp/known-good" && visudo -cf "$tmp/known-good" >/dev/null 2>&1; then
  mkdir "$tmp/sd"
  out=$(AEGIS_SUDOERS_DIR="$tmp/sd" AEGIS_PASSWD='youruser:x:1000:1000::/home/youruser:/bin/sh' sh "$script" 1000)
  [[ $out == "installed $tmp/sd/adguardvpn-cli for youruser" ]] || fail "unexpected install message: $out"
  [[ $(ls -A "$tmp/sd") == "adguardvpn-cli" ]] || fail "install must leave exactly one file: $(ls -A "$tmp/sd")"
  [[ $(stat -c %a "$tmp/sd/adguardvpn-cli") == 440 ]] || fail "the rule file must be mode 0440"
  [[ $(grep -v '^#' "$tmp/sd/adguardvpn-cli") == "$readme" ]] || fail "the installed rule must be the README's"
  grep -q '^# AdGuard VPN CLI' "$tmp/sd/adguardvpn-cli" || fail "the file should say what it is"
  bash "$dir/tests/sudoers.test.sh" "$tmp/sd/adguardvpn-cli" youruser 1000 > /dev/null || fail "the installed file fails the README matcher"
  # a second run replaces the file in place
  AEGIS_SUDOERS_DIR="$tmp/sd" AEGIS_PASSWD='youruser:x:1000:1000::/home/youruser:/bin/sh' sh "$script" 1000 > /dev/null
  [[ $(ls -A "$tmp/sd") == "adguardvpn-cli" ]] || fail "reinstall must not leave extra files"
  refuse "a missing sudoers directory" env AEGIS_SUDOERS_DIR="$tmp/nowhere" AEGIS_PASSWD='x:x:1:1::/home/x:/bin/sh' sh "$script" 1
  notes="install checked"
else
  notes="visudo unusable here, install not checked"
fi

echo "sudo_rule: ok ($notes)"
