#!/usr/bin/env bash
# gig-server.test.sh — drives gig-server/install.sh against a FIXTURE gig (#36).
#
# gig is private and has no release, and its source may not land in this
# public repo, so the test builds a minimal fake gig whose install.sh honours
# the real contract (--from TARBALL, /opt/gig/<version>, the /usr/local/bin/gig
# link, nothing done when that version is current) and whose bin/gig answers
# `version`, `config check` and `host apply`. The real tarball is always
# operator-supplied. garm's assets are the REAL releases, downloaded once and
# checked against gig-server/checksums; the refusals are fed tampered copies
# through GIG_SERVER_ASSET_DIR.
#
#   bash test/gig-server.test.sh             refusals only; no root, no writes
#                                            outside a temp dir
#   bash test/gig-server.test.sh --converge  as root in a throwaway debian:13
#                                            container (CI): refusals leave
#                                            nothing installed, then two
#                                            converges, an empty diff, the
#                                            acceptance checks, filled slots
#                                            surviving a re-converge
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROLE="$ROOT/gig-server"
CONVERGE=0
[ "${1:-}" = "--converge" ] && CONVERGE=1
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

failures=0
report() { printf 'gig-server.test: %s\n' "$*"; }
fail() { printf 'gig-server.test: FAIL — %s\n' "$*" >&2; failures=$((failures + 1)); }
check() { # check NAME CMD... — PASS when CMD succeeds
  local name=$1
  shift
  if "$@"; then report "PASS — $name"; else fail "$name"; fi
}

# --- fixtures ----------------------------------------------------------------

# The real garm assets, once, verified against the role's own record.
ASSETS="$TMP/assets"
mkdir -p "$ASSETS"
fetch_real() {
  local asset=$1 url=$2 want
  want="$(awk -v a="$asset" '!/^#/ && $1 == a { print $3 }' "$ROLE/checksums")"
  curl -fsSL -o "$ASSETS/$asset" "$url/$asset"
  [ "$(sha256sum "$ASSETS/$asset" | cut -d' ' -f1)" = "$want" ] || {
    echo "gig-server.test: the published $asset does not match gig-server/checksums" >&2
    exit 1
  }
}
fetch_real garm-linux-amd64.tgz https://github.com/cloudbase/garm/releases/download/v0.2.1
fetch_real garm-cli-linux-amd64.tgz https://github.com/cloudbase/garm/releases/download/v0.2.1
fetch_real garm-provider-incus-linux-amd64.tgz https://github.com/cloudbase/garm-provider-incus/releases/download/v0.1.5
fetch_real yq_linux_amd64 https://github.com/mikefarah/yq/releases/download/v4.54.3

# The fake gig release: one top-level directory, as GitHub's source tarballs.
GIG_VERSION=0.0.0-fixture
build_gig() { # build_gig OUT.tar.gz
  local top="$TMP/gigsrc/heavy-duty-gig-fixture"
  rm -rf "$TMP/gigsrc"
  mkdir -p "$top/bin"
  printf '%s\n' "$GIG_VERSION" >"$top/VERSION"
  cat >"$top/bin/gig" <<'EOF'
#!/usr/bin/env bash
# fixture gig: the three verbs the gig-server role calls.
set -euo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
case "${1:-}" in
  version) cat "$here/VERSION" ;;
  config)
    [ "${2:-}" = check ] && [ -r "${3:-}" ] || exit 2
    [ "$(yq e '.version' "$3")" = 1 ] || { echo "gig: $3: version must be 1" >&2; exit 1; }
    echo "gig: $3: ok" ;;
  host) echo "gig host $*" >>/tmp/gig-host-apply.log ;;
  *) exit 2 ;;
esac
EOF
  cat >"$top/install.sh" <<'EOF'
#!/usr/bin/env bash
# fixture install.sh: gig's --from contract, nothing more.
set -euo pipefail
[ "${1:-}" = --from ] && [ -r "${2:-}" ] || exit 2
sha="$(sha256sum "$2" | cut -d' ' -f1)"
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
tar -xzf "$2" -C "$t"
src="$(find "$t" -mindepth 1 -maxdepth 1)"
v="$(cat "$src/VERSION")"
if [ "$(readlink /usr/local/bin/gig 2>/dev/null)" = "/opt/gig/$v/bin/gig" ] &&
  [ "$(cat "/opt/gig/$v/.gig-source" 2>/dev/null)" = "$sha" ]; then
  echo "install.sh: gig $v is already installed and current; nothing to do"; exit 0
fi
mkdir -p /opt/gig /usr/local/bin
rm -rf "/opt/gig/$v"; cp -R "$src" "/opt/gig/$v"
printf '%s\n' "$sha" >"/opt/gig/$v/.gig-source"
ln -sfn "/opt/gig/$v/bin/gig" /usr/local/bin/gig
echo "install.sh: gig $v installed"
EOF
  chmod 0755 "$top/bin/gig" "$top/install.sh"
  # Fixed mtimes and owners: the same tarball, byte for byte, on every build.
  tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
    -C "$TMP/gigsrc" -cf - heavy-duty-gig-fixture | gzip -n >"$1"
}
build_gig "$TMP/gig.tar.gz"

# The config: gig's documented shape, the keys the role reads.
write_config() { # write_config OUT [GARM_PIN] [HOST_USER] [PROVIDER_PIN] [VERSION]
  cat >"$1" <<EOF
version: ${5:-1}
pins:
  garm: ${2:-v0.2.1}
  garm_provider_incus: ${4:-v0.1.5}
  actions_runner: v2.338.2
  debian_base: images:debian/13/cloud
host:
  user: ${3:-gig}
  pool: gig
  network: boxnet
  box_profile: box-profile
  callback_port: 9997
  grant:
    pool_size: 200GiB
    memory: 16GiB
    cpu: 6
    instances: 6
EOF
}
write_config "$TMP/gig.yaml"
write_config "$TMP/unrecorded.yaml" v0.2.2
write_config "$TMP/wronguser.yaml" v0.2.1 garm
write_config "$TMP/unrecorded-provider.yaml" v0.2.1 gig v0.1.6
write_config "$TMP/badversion.yaml" v0.2.1 gig v0.1.5 2

# box is stubbed on PATH: `version` answers BOX_STUB_VERSION, and each grant
# is recorded so the test reads what ran.
mkdir -p "$TMP/stubbin" "$TMP/foreignyq"
cat >"$TMP/stubbin/box" <<EOF
#!/usr/bin/env bash
case "\$1" in
  version) echo "box \${BOX_STUB_VERSION:-0.11.0} (/opt/box)" ;;
  grant) printf '%s\n' "\$*" >>"$TMP/box-grant.log" ;;
  *) exit 2 ;;
esac
EOF
# A foreign yq: Debian's kislyuk yq answers like this.
printf '#!/bin/sh\necho "yq 3.4.3"\n' >"$TMP/foreignyq/yq"
chmod 0755 "$TMP/stubbin/box" "$TMP/foreignyq/yq"

# A tampered copy of the asset set: one byte appended to garm's tarball.
mkdir -p "$TMP/tampered"
cp "$ASSETS"/* "$TMP/tampered/"
printf 'x' >>"$TMP/tampered/garm-linux-amd64.tgz"

run_role() { # run_role LOG [ENV=VAL...] — the role, as rig runs it
  local log=$1
  shift
  (cd "$ROLE" && env PATH="$TMP/stubbin:$PATH" GIG_SKIP_HOST_APPLY=1 GIG_SERVER_ASSET_DIR="$ASSETS" "$@" bash ./install.sh) >"$log" 2>&1
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

expect_refusal missing-inputs 2 "rig bootstrap gig-server" GIG_TARBALL= GIG_CONFIG=
expect_refusal missing-config 2 "GIG_CONFIG must name a readable file" GIG_TARBALL="$TMP/gig.tar.gz" GIG_CONFIG="$TMP/nope.yaml"
expect_refusal tampered-asset 1 "checksum mismatch" GIG_TARBALL="$TMP/gig.tar.gz" GIG_CONFIG="$TMP/gig.yaml" GIG_SERVER_ASSET_DIR="$TMP/tampered"
expect_refusal unrecorded-pin 1 "garm-linux-amd64.tgz v0.2.2 is not recorded" GIG_TARBALL="$TMP/gig.tar.gz" GIG_CONFIG="$TMP/unrecorded.yaml"
expect_refusal wrong-user 1 "host.user is 'garm'" GIG_TARBALL="$TMP/gig.tar.gz" GIG_CONFIG="$TMP/wronguser.yaml"
expect_refusal unrecorded-provider-pin 1 "garm-provider-incus-linux-amd64.tgz v0.1.6 is not recorded" GIG_TARBALL="$TMP/gig.tar.gz" GIG_CONFIG="$TMP/unrecorded-provider.yaml"
expect_refusal config-check 1 "gig config check refused it" GIG_TARBALL="$TMP/gig.tar.gz" GIG_CONFIG="$TMP/badversion.yaml"
expect_refusal box-too-old 1 "box 0.10.0 is older than 0.11.0" GIG_TARBALL="$TMP/gig.tar.gz" GIG_CONFIG="$TMP/gig.yaml" BOX_STUB_VERSION=0.10.0
expect_refusal foreign-yq 1 "will not shadow another yq" GIG_TARBALL="$TMP/gig.tar.gz" GIG_CONFIG="$TMP/gig.yaml" PATH="$TMP/stubbin:$TMP/foreignyq:$PATH"
if [ "$CONVERGE" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
  expect_refusal not-root 1 "must run as root" GIG_TARBALL="$TMP/gig.tar.gz" GIG_CONFIG="$TMP/gig.yaml"
fi

# --- converge (root, throwaway container only) -------------------------------

if [ "$CONVERGE" -eq 1 ]; then
  [ "$(id -u)" -eq 0 ] || { echo "gig-server.test: --converge needs root in a throwaway container" >&2; exit 2; }

  nothing_installed() {
    [ ! -e /usr/local/bin/gig ] && [ ! -e /opt/gig ] && [ ! -e /etc/gig ] &&
      [ ! -e /usr/local/bin/garm ] && [ ! -e /opt/garm ] && [ ! -e /etc/garm ] &&
      [ ! -e /etc/systemd/system/garm.service ] && ! getent passwd gig >/dev/null
  }
  # An existing gig that is not a no-login system account is refused.
  useradd --uid 1500 --shell /bin/bash --no-create-home gig
  expect_refusal human-gig 1 "above SYS_UID_MAX" GIG_TARBALL="$TMP/gig.tar.gz" GIG_CONFIG="$TMP/gig.yaml"
  userdel gig
  useradd --system --shell /bin/bash --no-create-home gig
  expect_refusal shell-gig 1 "login shell /bin/bash" GIG_TARBALL="$TMP/gig.tar.gz" GIG_CONFIG="$TMP/gig.yaml"
  userdel gig
  check "the refusals above left nothing installed" nothing_installed
  rm -f "$TMP/box-grant.log"

  snapshot() { # the converged state, as text
    {
      find /etc/gig /etc/garm /var/lib/garm /var/lib/gig /opt/gig /opt/garm /usr/local/bin \
        /etc/systemd/system /etc/systemd/journald.conf.d -mindepth 0 2>/dev/null | sort |
        while IFS= read -r p; do
          if [ -L "$p" ]; then
            printf '%s link %s\n' "$p" "$(readlink "$p")"
          elif [ -f "$p" ]; then
            printf '%s %s\n' "$(stat -c '%n %a %U:%G %s' "$p")" "$(sha256sum "$p" | cut -d' ' -f1)"
          else
            stat -c '%n %a %U:%G dir' "$p"
          fi
        done
      getent passwd gig
      id gig
    }
  }

  # The first converge downloads: the role builds the release URLs and curls.
  if run_role "$TMP/converge1.log" GIG_TARBALL="$TMP/gig.tar.gz" GIG_CONFIG="$TMP/gig.yaml" GIG_SERVER_ASSET_DIR=; then
    report "PASS — first converge, through the role's own downloads"
  else
    fail "first converge: $(cat "$TMP/converge1.log")"
  fi
  snapshot >"$TMP/snap1"
  if run_role "$TMP/converge2.log" GIG_TARBALL="$TMP/gig.tar.gz" GIG_CONFIG="$TMP/gig.yaml"; then
    report "PASS — second converge"
  else
    fail "second converge: $(cat "$TMP/converge2.log")"
  fi
  snapshot >"$TMP/snap2"
  if diff -u "$TMP/snap1" "$TMP/snap2"; then
    report "PASS — two converges leave an empty diff ($(wc -l <"$TMP/snap1") entries)"
  else
    fail "the second converge changed the host"
  fi
  if grep -q 'placed\|created' "$TMP/converge2.log"; then
    fail "the second converge reported a write: $(grep 'placed\|created' "$TMP/converge2.log")"
  fi

  grant="--service gig --pool gig --pool-size 200GiB --memory 16GiB --cpu 6 --instances 6"
  check "gig version answers" test "$(gig version)" = "$GIG_VERSION"
  check "gig is not in incus-admin" bash -c '! id -nG gig | tr " " "\n" | grep -qx incus-admin'
  # shellcheck disable=SC2016  # expands in the child bash
  check "gig has no login shell and no home" bash -c '[ "$(getent passwd gig | cut -d: -f6,7)" = "/nonexistent:/usr/sbin/nologin" ] && [ ! -e /nonexistent ]'
  check "box grant ran with gig.yaml's values, on every converge" \
    test "$(cat "$TMP/box-grant.log")" = "$(printf 'grant %s\ngrant %s' "$grant" "$grant")"
  check "/etc/gig/gig.yaml matches the input" cmp -s /etc/gig/gig.yaml "$TMP/gig.yaml"
  check "/etc/gig is 0755 root, gig.yaml 0644" test "$(stat -c '%a %U %a' /etc/gig /etc/gig/gig.yaml | tr '\n' ' ')" = "755 root 755 644 root 644 "
  check "notify.env is empty, 0600 root:root" test "$(stat -c '%s %a %U:%G' /etc/gig/notify.env)" = "0 600 root:root"
  check "app-key.pem is empty, 0600 gig:gig" test "$(stat -c '%s %a %U:%G' /etc/garm/app-key.pem)" = "0 600 gig:gig"
  check "/etc/garm, /var/lib/garm and /var/lib/gig are 0750 gig:gig" test "$(stat -c '%a %U:%G' /etc/garm /var/lib/garm /var/lib/gig | sort -u)" = "750 gig:gig"
  check "no config.toml is written" test ! -e /etc/garm/config.toml
  check "garm.service is installed" grep -qx 'ExecStart=/usr/local/bin/garm -config /etc/garm/config.toml' /etc/systemd/system/garm.service
  check "garm.service runs as gig, Restart=always" bash -c 'grep -qx User=gig /etc/systemd/system/garm.service && grep -qx Restart=always /etc/systemd/system/garm.service'
  # shellcheck disable=SC2016  # these expand in the child bash
  # No systemd in the container, so this proves the role never enables it:
  # no enable call in the script and no wants link on disk.
  check "garm.service is not enabled (no enable call, no wants link)" \
    bash -c '! grep -q "systemctl enable" "$1" && ! ls /etc/systemd/system/*.wants/garm.service >/dev/null 2>&1' _ "$ROLE/install.sh"
  check "the first converge placed yq" grep -q 'placed /usr/local/bin/yq' "$TMP/converge1.log"
  # shellcheck disable=SC2016  # expands in the child bash
  check "the second converge used the usable yq and placed none" \
    bash -c 'grep -q "yq: using /usr/local/bin/yq" "$1" && ! grep -q "placed /usr/local/bin/yq" "$1"' _ "$TMP/converge2.log"
  # shellcheck disable=SC2016  # expands in the child bash
  check "the unit is hardened" bash -c 'for k in NoNewPrivileges=yes PrivateTmp=yes ProtectSystem=strict "ReadWritePaths=/var/lib/garm /etc/garm"; do grep -qxF "$k" /etc/systemd/system/garm.service || exit 1; done'
  check "journald drop-in caps at 2G" grep -qx 'SystemMaxUse=2G' /etc/systemd/journald.conf.d/gig.conf
  check "garm --version matches the pin" test "$(/usr/local/bin/garm --version 2>&1)" = v0.2.1
  mkdir -p "$TMP/pin"
  tar -xzf "$ASSETS/garm-cli-linux-amd64.tgz" -C "$TMP/pin"
  tar -xzf "$ASSETS/garm-provider-incus-linux-amd64.tgz" -C "$TMP/pin"
  check "garm-cli is the pinned binary" cmp -s /usr/local/bin/garm-cli "$TMP/pin/garm-cli"
  check "the provider is the pinned binary" cmp -s /opt/garm/providers.d/garm-provider-incus "$TMP/pin/garm-provider-incus"
  check "host apply was skipped" test ! -e /tmp/gig-host-apply.log

  # Filled slots survive a re-converge byte for byte.
  printf -- '-----BEGIN FIXTURE KEY-----\nnot-a-secret\n' >/etc/garm/app-key.pem
  printf 'TELEGRAM_TOKEN=fixture\n' >/etc/gig/notify.env
  printf 'state\n' >/var/lib/gig/fixture-state
  chmod 0700 /var/lib/gig
  key_before="$(sha256sum /etc/garm/app-key.pem /etc/gig/notify.env /var/lib/gig/fixture-state)"
  if run_role "$TMP/converge3.log" GIG_TARBALL="$TMP/gig.tar.gz" GIG_CONFIG="$TMP/gig.yaml"; then
    check "filled app-key.pem and notify.env survive a re-converge" \
      test "$(sha256sum /etc/garm/app-key.pem /etc/gig/notify.env /var/lib/gig/fixture-state)" = "$key_before"
    check "/var/lib/gig keeps its contents and its drifted mode is corrected" \
      test "$(stat -c '%a %U:%G' /var/lib/gig)" = "750 gig:gig"
  else
    fail "third converge: $(cat "$TMP/converge3.log")"
  fi
fi

if [ "$failures" -ne 0 ]; then
  report "$failures failure(s)"
  exit 1
fi
report "all checks passed"
