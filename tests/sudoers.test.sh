#!/usr/bin/env bash
# The sudoers rule README.md tells users to install: it must parse, and its
# argument regex must match the one command adguardvpn-cli runs through sudo
# and nothing broader.
#
#   tests/sudoers.test.sh                  check the rule in README.md
#   tests/sudoers.test.sh FILE USER UID    check a filled-in rule file
#
# sudoers(5): "Command line arguments are matched as a single, concatenated
# string", and an argument regex (^...$) is a POSIX ERE matched against it.
# So every case is the argv sudo sees after `env`, joined with single spaces,
# matched with grep -Ez (NUL-terminated records: a newline is just a
# character, and ^/$ anchor to the whole string), in the C and a UTF-8 locale.
set -euo pipefail
dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

if (( $# )); then
  (( $# == 3 )) || { echo "usage: $0 [FILE USER UID]" >&2; exit 2; }
  rule=$(grep -v -E '^[[:space:]]*(#|$)' "$1" || true)
  user=$2 uid=$3
else
  rule=$(grep -E '^[[:space:]]*youruser ALL=' "$dir/README.md" || true)
  user=youruser uid=1000
fi
[[ -n $rule && $(printf '%s\n' "$rule" | wc -l) == 1 ]] || { echo "sudoers: expected exactly one rule line, got: $rule" >&2; exit 1; }
rule=${rule#"${rule%%[![:space:]]*}"}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf '%s\n' "$rule" > "$tmp/rule"

# The user, as root, without a password, runs /usr/bin/env with an anchored
# argument regex.
prefix="$user ALL=(root) NOPASSWD: /usr/bin/env "
[[ ${rule:0:${#prefix}} == "$prefix" ]] || { echo "sudoers: rule must start with: $prefix" >&2; exit 1; }
args=${rule:${#prefix}}
[[ $args == ^*'$' ]] || { echo "sudoers: arguments must be a regex from ^ to \$" >&2; exit 1; }

# visudo checks the syntax; it works unprivileged on a file you can read.
# If it can't run here (missing, or refuses a known-good file), skip that part.
notes="visudo not found, syntax check skipped"
if command -v visudo >/dev/null 2>&1; then
  printf 'nobody ALL=(root) NOPASSWD: /usr/bin/true\n' > "$tmp/known-good"
  if visudo -cf "$tmp/known-good" >/dev/null 2>&1; then
    visudo -cf "$tmp/rule" >/dev/null 2>&1 || { visudo -cf "$tmp/rule" >&2 || true; echo "sudoers: visudo rejects the rule" >&2; exit 1; }
    notes="visudo -cf passed"
  else
    notes="visudo -cf unusable here, syntax check skipped"
  fi
fi
# cvtsudoers shows what sudo's own parser made of the line: the stored
# argument string must be exactly the regex tested below (no escapes eaten,
# no whitespace folded), with runas root and no authentication.
if command -v cvtsudoers >/dev/null 2>&1 && cvtsudoers -f json "$tmp/rule" > "$tmp/rule.json" 2>/dev/null; then
  jq -e --arg cmd "/usr/bin/env $args" --arg user "$user" '
    [.User_Specs[] | .User_List == [{username: $user}] and .Host_List == [{hostname: "ALL"}]
      and ([.Cmnd_Specs[] | .runasusers == [{username: "root"}] and .Options == [{authenticate: false}]
            and .Commands == [{command: $cmd}]] == [true])] == [true]
  ' "$tmp/rule.json" >/dev/null || { echo "sudoers: sudo's parser reads the rule differently:" >&2; cat "$tmp/rule.json" >&2; exit 1; }
  notes+=", cvtsudoers parse agrees"
fi

home=/home/$user
data=$home/.local/share
cli=/opt/adguardvpn_cli/adguardvpn-cli
envs=("HOME=$home" "XDG_DATA_HOME=$data" "DISPLAY=:1" "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus")
tail_args=(--log-to-file --wait-for-parent --ppid-file "$data/adguardvpn-cli/vpn.pid")
: > "$tmp/match"
: > "$tmp/reject"

# add match|reject ARG...: one case, joined the way sudo joins the argv
add() {
  local want=$1 IFS=' '
  shift
  printf '%s\0' "$*" >> "$tmp/$want"
}
# connect match|reject DISPLAY LOCATION [ARG...]: the argv the CLI hands to
# `sudo -b env`, with ARG... after the location (where the CLI puts -v)
connect() {
  local want=$1 display=$2 location=$3
  shift 3
  add "$want" "HOME=$home" "XDG_DATA_HOME=$data" "DISPLAY=$display" "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus" \
    "$cli" connect --no-fork -l "$location" "$@" "${tail_args[@]}"
}

# --- must match: the real command, for any location, with or without -v
mapfile -t cities < <(jq -r '.[].city' "$dir/assets/locations.json")
for location in "Johannesburg" "Tel Aviv" "Shanghai (Virtual)" "Chișinău" "São Paulo" "${cities[@]}"; do
  for display in :0 :1; do
    connect match "$display" "$location"
    connect match "$display" "$location" -v
  done
done
connect match :1.0 "Tel Aviv"
connect match :10 "Tel Aviv" -v

# --- must reject: other subcommands
add reject "${envs[@]}" "$cli" export-logs -o /etc/x -f
add reject "${envs[@]}" "$cli" config set-tun-routing-mode script
add reject "${envs[@]}" "$cli" config create-route-script
add reject "${envs[@]}" "$cli" update
add reject "${envs[@]}" "$cli" --version
add reject "${envs[@]}" "$cli"

# --- must reject: options smuggled in with the location
connect reject :1 "X" --pid-file /tmp/x
connect reject :1 "X --pid-file /tmp/x"
connect reject :1 "X" --boot
connect reject :1 "X --boot"
connect reject :1 "--fastest"
connect reject :1 "-f"
connect reject :1 "X" -v -v
connect reject :1 "X" -y
connect reject :1 ""
connect reject :1 $'X\n--boot'
connect reject :1 $'X\t--boot'
add reject "${envs[@]}" "$cli" connect --no-fork "${tail_args[@]}"
add reject "${envs[@]}" "$cli" connect --no-fork --fastest "${tail_args[@]}"
add reject "${envs[@]}" "$cli" connect --no-fork -v -l X "${tail_args[@]}"

# --- must reject: anything else around the command changed
add reject "${envs[@]}" "$cli" connect --no-fork -l X --log-to-file --wait-for-parent --ppid-file /tmp/vpn.pid
add reject "${envs[@]}" "$cli" connect --no-fork -l X --log-to-file --wait-for-parent --ppid-file "$data/adguardvpn-cli/vpnxpid"
add reject "${envs[@]}" "$cli" connect --no-fork -l X --log-to-file --wait-for-parent --pid-file "$data/adguardvpn-cli/vpn.pid"
add reject "${envs[@]}" "$cli" connect -l X "${tail_args[@]}"
add reject "${envs[@]}" "$cli" connect --no-fork -l X --log-to-file --ppid-file "$data/adguardvpn-cli/vpn.pid"
add reject "${envs[@]}" "$cli" connect --no-fork -l X "${tail_args[@]}" --boot
add reject "${envs[@]}" "$cli" connect --no-fork -l X "${tail_args[@]}" x
add reject "HOME=/root" "${envs[@]:1}" "$cli" connect --no-fork -l X "${tail_args[@]}"
add reject "HOME=${home}x" "${envs[@]:1}" "$cli" connect --no-fork -l X "${tail_args[@]}"
add reject "${envs[0]}" "XDG_DATA_HOME=/tmp" "${envs[@]:2}" "$cli" connect --no-fork -l X "${tail_args[@]}"
add reject "${envs[0]}" "XDG_DATA_HOME=$home/xlocal/share" "${envs[@]:2}" "$cli" connect --no-fork -l X "${tail_args[@]}"
add reject "${envs[@]:0:3}" "DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/bus" "$cli" connect --no-fork -l X "${tail_args[@]}"
add reject "${envs[@]}" "LD_PRELOAD=/tmp/x.so" "$cli" connect --no-fork -l X "${tail_args[@]}"
add reject "LD_PRELOAD=/tmp/x.so" "${envs[@]}" "$cli" connect --no-fork -l X "${tail_args[@]}"
add reject -i "${envs[@]}" "$cli" connect --no-fork -l X "${tail_args[@]}"
add reject "${envs[@]}" /tmp/adguardvpn-cli connect --no-fork -l X "${tail_args[@]}"
add reject "${envs[@]}" /opt/adguardvpn_cli/../adguardvpn_cli/adguardvpn-cli connect --no-fork -l X "${tail_args[@]}"
connect reject "" "Tel Aviv"
connect reject ":1 x" "Tel Aviv"
connect reject ":1;" "Tel Aviv"

show() { sed -z 's/\n/\\n/g; s/\t/\\t/g' | tr '\0' '\n' | sed 's/^/  /' >&2; }
count() { tr -cd '\0' < "$1" | wc -c; }
failed=0
for locale in C C.UTF-8; do
  # every match case must match: grep -v prints the ones that don't
  rc=0; LC_ALL=$locale grep -Ezv -- "$args" "$tmp/match" > "$tmp/out" || rc=$?
  (( rc <= 1 )) || { echo "sudoers: grep -E can't use the argument regex" >&2; exit 1; }
  if [[ -s $tmp/out ]]; then echo "sudoers: should match but doesn't ($locale):" >&2; show < "$tmp/out"; failed=1; fi
  # no reject case may match
  rc=0; LC_ALL=$locale grep -Ez -- "$args" "$tmp/reject" > "$tmp/out" || rc=$?
  (( rc <= 1 )) || { echo "sudoers: grep -E can't use the argument regex" >&2; exit 1; }
  if [[ -s $tmp/out ]]; then echo "sudoers: should be refused but matches ($locale):" >&2; show < "$tmp/out"; failed=1; fi
done
(( ! failed )) || exit 1
echo "sudoers: ok ($(count "$tmp/match") commands match, $(count "$tmp/reject") refused; $notes)"
