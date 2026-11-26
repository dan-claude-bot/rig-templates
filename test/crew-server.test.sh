#!/usr/bin/env bash
# crew-server.test.sh — drives crew-server/install.sh (#46).
#
# crew is public, so the artifact is the REAL release, downloaded once and
# checked against crew-server/checksums; the refusals are fed a tampered copy
# through CREW_SERVER_ASSET_DIR. box and tailscale are stubs on PATH. The
# service verbs (`crew service setup|check`) need Incus and systemd, which no
# container has: the converge drives them through a stub `crew` that records
# its arguments and hands every other verb to the real one. The real setup and
# check are read on a VM (README, "Read on a real host").
#
#   bash test/crew-server.test.sh             refusals only; no root, no writes
#                                             outside a temp dir
#   bash test/crew-server.test.sh --converge  as root in a throwaway debian:13
#                                             container (CI): refusals leave
#                                             nothing installed, two converges
#                                             with an empty diff, the service
#                                             path through the stub
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROLE="$ROOT/crew-server"
CONVERGE=0
[ "${1:-}" = "--converge" ] && CONVERGE=1
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

failures=0
report() { printf 'crew-server.test: %s\n' "$*"; }
fail() { printf 'crew-server.test: FAIL — %s\n' "$*" >&2; failures=$((failures + 1)); }
check() { # check NAME CMD... — PASS when CMD succeeds
  local name=$1
  shift
  if "$@"; then report "PASS — $name"; else fail "$name"; fi
}

# --- fixtures ----------------------------------------------------------------

VERSION="$(sed -n 's/^CREW_VERSION=//p' "$ROLE/install.sh")"
ASSET="crew-$VERSION.sh"
ASSETS="$TMP/assets"
mkdir -p "$ASSETS"
want="$(awk -v a="$ASSET" '!/^#/ && $1 == a { print $3 }' "$ROLE/checksums")"
curl -fsSL -o "$ASSETS/$ASSET" "https://github.com/heavy-duty/crew/releases/download/$VERSION/$ASSET"
[ "$(sha256sum "$ASSETS/$ASSET" | cut -d' ' -f1)" = "$want" ] || {
  echo "crew-server.test: the published $ASSET does not match crew-server/checksums" >&2
  exit 1
}

mkdir -p "$TMP/tampered"
cp "$ASSETS/$ASSET" "$TMP/tampered/"
printf 'x' >>"$TMP/tampered/$ASSET"

# A copy of the role whose checksums record nothing for the pinned version.
cp -R "$ROLE" "$TMP/unrecorded"
grep -v "^$ASSET " "$ROLE/checksums" >"$TMP/unrecorded/checksums"

# Stubs: box answers BOX_STUB_VERSION; tailscale answers TS_STUB_IP.
mkdir -p "$TMP/stubbin" "$TMP/notailscale"
cat >"$TMP/stubbin/box" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  version) echo "box ${BOX_STUB_VERSION:-0.11.0} (/opt/box)" ;;
  *) exit 2 ;;
esac
EOF
cat >"$TMP/stubbin/tailscale" <<'EOF'
#!/usr/bin/env bash
[ "$*" = "ip -4" ] && [ -n "${TS_STUB_IP:-}" ] && echo "$TS_STUB_IP"
EOF
chmod 0755 "$TMP/stubbin/box" "$TMP/stubbin/tailscale"
cp "$TMP/stubbin/box" "$TMP/notailscale/box"

run_role() { # run_role LOG [ENV=VAL...] — the role, as rig runs it
  local log=$1 dir="$ROLE"
  shift
  [ "${ROLE_DIR:-}" ] && dir="$ROLE_DIR"
  (cd "$dir" && env PATH="$TMP/stubbin:$PATH" CREW_SERVER_ASSET_DIR="$ASSETS" TS_STUB_IP=100.101.102.103 "$@" bash ./install.sh) >"$log" 2>&1
}
expect_refusal() { # expect_refusal NAME CODE MESSAGE [ENV=VAL...]
  local name=$1 code=$2 msg=$3 rc=0
  shift 3
  run_role "$TMP/$name.log" "$@" || rc=$?
  if [ "$rc" -ne "$code" ]; then
    fail "$name: want exit $code, got $rc: $(cat "$TMP/$name.log")"
  elif ! grep -qF -- "$msg" "$TMP/$name.log"; then
    fail "$name: refused but never says '$msg': $(cat "$TMP/$name.log")"
  else
    report "PASS — $name is refused (exit $code): $(grep -F -- "$msg" "$TMP/$name.log" | head -1)"
  fi
}

# --- refusals (both modes) ---------------------------------------------------

expect_refusal unknown-operator 2 "no local user 'no-such-operator-46'" CREW_OPERATORS="root,no-such-operator-46"
# shellcheck disable=SC2016  # the literal is the point: it must be refused unexpanded
expect_refusal operator-shape 2 "is not a user name" CREW_OPERATORS='root,$(id)'
expect_refusal bad-port 2 "CREW_PORT: '99999' is not a port" CREW_PORT=99999
expect_refusal bad-bind 2 "CREW_BIND: 'floor.example' is not an IP address" CREW_BIND=floor.example
expect_refusal no-tailnet 2 "no tailnet IPv4" PATH="$TMP/notailscale:$PATH"
expect_refusal tailnet-down 2 "no tailnet IPv4" TS_STUB_IP=
expect_refusal bad-memory 2 "CREW_MEMORY: 'lots' is not a size" CREW_MEMORY=lots
expect_refusal pool-alone 2 "CREW_POOL and CREW_POOL_SIZE go together" CREW_POOL=crew
expect_refusal tampered-artifact 1 "checksum mismatch" CREW_SERVER_ASSET_DIR="$TMP/tampered"
ROLE_DIR="$TMP/unrecorded" expect_refusal unrecorded-version 1 "is not recorded in crew-server/checksums"
expect_refusal box-too-old 1 "box 0.10.0 is older than 0.11.0" BOX_STUB_VERSION=0.10.0
if [ "$CONVERGE" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
  expect_refusal not-root 1 "must run as root"
  # CREW_SKIP_SERVICE needs no tailnet: it never starts the floor.
  expect_refusal skip-needs-no-tailnet 1 "must run as root" CREW_SKIP_SERVICE=1 PATH="$TMP/notailscale:$PATH"
fi

# --- converge (root, throwaway container only) -------------------------------

if [ "$CONVERGE" -eq 1 ]; then
  [ "$(id -u)" -eq 0 ] || { echo "crew-server.test: --converge needs root in a throwaway container" >&2; exit 2; }

  nothing_installed() { [ ! -e /usr/local/bin/crew ] && [ ! -e /opt/crew ]; }
  check "the refusals above left nothing installed" nothing_installed

  snapshot() { # the installed state, as text
    find /opt/crew /usr/local/bin -mindepth 0 2>/dev/null | sort |
      while IFS= read -r p; do
        if [ -L "$p" ]; then
          printf '%s link %s\n' "$p" "$(readlink "$p")"
        elif [ -f "$p" ]; then
          printf '%s %s\n' "$(stat -c '%n %a %U:%G %s %Y' "$p")" "$(sha256sum "$p" | cut -d' ' -f1)"
        else
          stat -c '%n %a %U:%G dir %Y' "$p"
        fi
      done
  }

  # The first converge downloads: the role builds the release URL and curls.
  if run_role "$TMP/converge1.log" CREW_SKIP_SERVICE=1 CREW_SERVER_ASSET_DIR=; then
    report "PASS — first converge (CREW_SKIP_SERVICE=1), through the role's own download"
  else
    fail "first converge: $(cat "$TMP/converge1.log")"
  fi
  snapshot >"$TMP/snap1"
  if run_role "$TMP/converge2.log" CREW_SKIP_SERVICE=1; then
    report "PASS — second converge"
  else
    fail "second converge: $(cat "$TMP/converge2.log")"
  fi
  snapshot >"$TMP/snap2"
  if diff -u "$TMP/snap1" "$TMP/snap2"; then
    report "PASS — two converges leave an empty diff ($(wc -l <"$TMP/snap1") entries, mtimes included)"
  else
    fail "the second converge changed the host"
  fi
  check "crew --version answers the pinned version" test "$(crew --version | awk '{ print $2 }')" = "$VERSION"
  check "/usr/local/bin/crew resolves into /opt/crew/versions/$VERSION" \
    test "$(readlink -f /usr/local/bin/crew)" = "/opt/crew/versions/$VERSION/cli/crew"
  check "the second converge skipped the installer" grep -q "crew $VERSION is already installed and current" "$TMP/converge2.log"
  check "CREW_SKIP_SERVICE=1 ran no service verb" grep -q "no service setup, no operators, no check" "$TMP/converge2.log"
  check "the role wrote nothing under /var/lib/crew or /etc/crew" bash -c '[ ! -e /var/lib/crew ] && [ ! -e /etc/crew ]'

  # A tampered artifact on a host that already has crew changes nothing.
  snapshot >"$TMP/snap3"
  expect_refusal tampered-on-installed 1 "checksum mismatch" CREW_SKIP_SERVICE=1 CREW_SERVER_ASSET_DIR="$TMP/tampered"
  snapshot >"$TMP/snap4"
  check "...and the installed crew is untouched" cmp -s "$TMP/snap3" "$TMP/snap4"

  # The service path, through a stub crew that records `service` calls and
  # makes group crew on setup (as the real setup does); every other verb is
  # the real crew.
  mkdir -p "$TMP/crewstub"
  cat >"$TMP/crewstub/crew" <<EOF
#!/usr/bin/env bash
if [ "\$1" = service ]; then
  printf '%s\n' "\$*" >>"$TMP/service.log"
  case "\$2" in
    setup) getent group crew >/dev/null || groupadd --system crew; echo "  the floor: http://<this host>:8420/ — user and password in /etc/crew/floor.env" ;;
    check) [ -f "$TMP/check-drift" ] && { echo "service: DRIFT — re-run: sudo crew service setup"; exit 1; }; echo "service: clean" ;;
  esac
  exit 0
fi
exec /usr/local/bin/crew "\$@"
EOF
  chmod 0755 "$TMP/crewstub/crew"
  useradd --create-home --shell /bin/bash op46
  svc() { run_role "$1" PATH="$TMP/crewstub:$TMP/stubbin:$PATH" CREW_OPERATORS="op46" "${@:2}"; }

  if svc "$TMP/svc1.log" CREW_MEMORY=8GiB CREW_INSTANCES=4; then
    report "PASS — service converge (stub setup and check)"
  else
    fail "service converge: $(cat "$TMP/svc1.log")"
  fi
  check "setup ran with the tailnet address, the default port and the caps" \
    grep -qxF "service setup --port 8420 --bind 100.101.102.103 --instances 4 --memory 8GiB" "$TMP/service.log"
  check "the check ran after setup" test "$(sed -n 2p "$TMP/service.log")" = "service check"
  check "the operator is in group crew" bash -c 'id -nG op46 | tr " " "\n" | grep -qx crew'
  check "the converge names the floor and where its password is" \
    grep -qF "the floor is http://100.101.102.103:8420/ — its password is in /etc/crew/floor.env" "$TMP/svc1.log"
  : >"$TMP/service.log"
  if svc "$TMP/svc2.log" CREW_BIND=10.0.0.5 CREW_PORT=9000; then
    check "a re-run converges setup again, with CREW_BIND and CREW_PORT" \
      grep -qxF "service setup --port 9000 --bind 10.0.0.5" "$TMP/service.log"
    # shellcheck disable=SC2016  # expands in the child bash
    check "...and adds no operator twice" bash -c '! grep -q "added op46" "$1"' _ "$TMP/svc2.log"
  else
    fail "service re-run: $(cat "$TMP/svc2.log")"
  fi
  touch "$TMP/check-drift"
  rc=0
  svc "$TMP/svc3.log" || rc=$?
  check "a check that does not read clean fails the converge" test "$rc" -eq 1
  check "...with crew's own output" grep -q "service: DRIFT" "$TMP/svc3.log"
fi

if [ "$failures" -ne 0 ]; then
  report "$failures failure(s)"
  exit 1
fi
report "all checks passed"
