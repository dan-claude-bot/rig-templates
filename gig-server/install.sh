#!/usr/bin/env bash
# gig-server — the machine role that brings up gig's host (#36,
# heavy-duty/gig#3). rig runs this AS ROOT, last, from this directory; it is
# equally runnable on its own with the same two inputs (see README).
#
# It places gig, its config, garm's binaries, a service user, box's grant for
# that user and an inert garm.service. It places SLOTS, never secrets:
# notify.env and app-key.pem are created empty and never overwritten, and
# garm's config.toml is gig's engine's to render (heavy-duty/gig#4).
#
# Two phases. Everything that can refuse — the inputs, `gig config check`,
# the pins against ./checksums, every download's sha256 — runs first, in a
# temporary directory, so a refusal leaves nothing installed. Only then does
# the second phase write to the host, and every write is cmp-guarded or
# created-if-absent, so a re-run with the same inputs changes nothing.
#
# Inputs (environment):
#   GIG_TARBALL           a gig release source tarball (operator-supplied)
#   GIG_CONFIG            heavy-duty/infra's gig.yaml (operator-supplied)
#   GIG_SKIP_HOST_APPLY   1 skips gig's two `host apply` halves (container CI,
#                         which has no Incus)
#   GIG_SERVER_ASSET_DIR  read release assets from this directory instead of
#                         downloading them; ./checksums is enforced either way
#
# Exit codes: 0 converged, 1 refused or failed, 2 missing inputs.
set -euo pipefail
umask 022

PROG=gig-server
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKSUMS="$HERE/checksums"
SERVICE_USER=gig
YQ_VERSION=v4.54.3
GARM_URL=https://github.com/cloudbase/garm/releases/download
PROVIDER_URL=https://github.com/cloudbase/garm-provider-incus/releases/download
YQ_URL=https://github.com/mikefarah/yq/releases/download
SAFE_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'
BOX_FLOOR=0.11.0

log() { printf '%s: %s\n' "$PROG" "$*"; }
die() {
  local code=$1
  shift
  printf '%s: %s\n' "$PROG" "$*" >&2
  exit "$code"
}

INVOCATION="GIG_TARBALL=/path/to/gig-<version>.tar.gz GIG_CONFIG=/path/to/infra/gig.yaml rig bootstrap gig-server --users <path>"
for input in GIG_TARBALL GIG_CONFIG; do
  path="${!input:-}"
  if [ -z "$path" ] || [ ! -f "$path" ] || [ ! -r "$path" ]; then
    printf '%s: %s must name a readable file (got: %s)\n' "$PROG" "$input" "${path:-unset}" >&2
    printf '%s: run it as:\n  %s\n' "$PROG" "$INVOCATION" >&2
    printf '%s: or, on a host that already carries another rig role:\n  %s\n' "$PROG" \
      "GIG_TARBALL=... GIG_CONFIG=... bash gig-server/install.sh" >&2
    exit 2
  fi
done
GIG_TARBALL="$(realpath -- "$GIG_TARBALL")"
GIG_CONFIG="$(realpath -- "$GIG_CONFIG")"

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/dl" "$WORK/gig" "$WORK/new"

# --- phase 1: verify everything, write nothing outside $WORK ------------------

# recorded_sha ASSET VERSION: the sha256 ./checksums records, or a refusal.
recorded_sha() {
  local sha
  sha="$(awk -v a="$1" -v v="$2" '!/^[[:space:]]*#/ && $1 == a && $2 == v { print $3 }' "$CHECKSUMS")"
  if ! [[ $sha =~ ^[0-9a-f]{64}$ ]]; then
    die 1 "$1 $2 is not recorded in gig-server/checksums; a pin bump is a role PR that records its sha256 — refusing"
  fi
  printf '%s\n' "$sha"
}

# fetch ASSET VERSION URL: the asset into $WORK/dl, verified, or a refusal.
fetch() {
  local asset=$1 version=$2 url=$3 want got dest="$WORK/dl/$1"
  want="$(recorded_sha "$asset" "$version")" || exit 1
  if [ -n "${GIG_SERVER_ASSET_DIR:-}" ]; then
    [ -f "$GIG_SERVER_ASSET_DIR/$asset" ] || die 1 "$asset: not in GIG_SERVER_ASSET_DIR ($GIG_SERVER_ASSET_DIR)"
    cp -- "$GIG_SERVER_ASSET_DIR/$asset" "$dest"
  else
    command -v curl >/dev/null 2>&1 || die 1 "curl is needed to download $asset"
    curl -fsSL --proto '=https' -o "$dest" -- "$url/$version/$asset" || die 1 "download of $asset $version failed"
  fi
  got="$(sha256sum -- "$dest" | cut -d' ' -f1)"
  [ "$got" = "$want" ] || die 1 "$asset $version: checksum mismatch (recorded $want, got $got) — refusing"
}

# unpack ASSET BINARY: the one regular file BINARY out of a verified tgz.
unpack() {
  local listing
  listing="$(tar -tzf "$WORK/dl/$1")" || die 1 "$1: not a readable .tgz"
  [ "$listing" = "$2" ] || die 1 "$1: expected exactly one file '$2', got: $(printf '%s' "$listing" | tr '\n' ' ')"
  tar -xzf "$WORK/dl/$1" -C "$WORK/new" --no-same-owner --no-same-permissions -- "$2"
  if [ ! -f "$WORK/new/$2" ] || [ -L "$WORK/new/$2" ]; then die 1 "$1: $2 is not a regular file"; fi
  chmod 0755 "$WORK/new/$2"
}

# yq_usable: mikefarah's yq v4.54+ on PATH (gig's own floor, lib/config.sh).
yq_usable() {
  local v
  v="$(yq --version 2>/dev/null || true)"
  [[ $v =~ mikefarah/yq.*\ version\ v?4\.([0-9]+) ]] && [ "$((10#${BASH_REMATCH[1]}))" -ge 54 ]
}

# gig finds yq only as `yq` on PATH (no override, no libexec), so a private
# copy cannot be wired in. A yq that is not gig's (Debian's kislyuk yq, an old
# mikefarah) is refused rather than shadowed for every user of the host.
YQ_PLACE=0
if yq_usable; then
  log "yq: using $(command -v yq)"
elif command -v yq >/dev/null 2>&1; then
  die 1 "$(command -v yq) is not mikefarah's yq v4.54+ ($(yq --version 2>&1 | head -n1)); gig needs it as 'yq' on PATH and this role will not shadow another yq — remove it (Debian: apt-get remove yq) or install mikefarah's yq v4.54+"
else
  fetch yq_linux_amd64 "$YQ_VERSION" "$YQ_URL"
  install -m 0755 "$WORK/dl/yq_linux_amd64" "$WORK/bin/yq"
  YQ_PLACE=1
  log "yq: will place mikefarah's yq $YQ_VERSION at /usr/local/bin/yq"
fi
export PATH="$WORK/bin:$PATH"

# The tarball unpacks here only to run its own `config check` before
# anything is installed; its install.sh does the real, checked install below.
tar -xzf "$GIG_TARBALL" -C "$WORK/gig" --no-same-owner --no-same-permissions 2>/dev/null || die 1 "$GIG_TARBALL: not a readable .tar.gz"
mapfile -t tops < <(find "$WORK/gig" -mindepth 1 -maxdepth 1)
if [ "${#tops[@]}" -ne 1 ] || [ ! -d "${tops[0]}" ] || [ -L "${tops[0]}" ]; then
  die 1 "$GIG_TARBALL: expected exactly one top-level directory"
fi
SRC="${tops[0]}"
if [ ! -f "$SRC/install.sh" ] || [ ! -x "$SRC/bin/gig" ]; then
  die 1 "$GIG_TARBALL: no install.sh and bin/gig; not a gig release"
fi

"$SRC/bin/gig" config check "$GIG_CONFIG" || die 1 "$GIG_CONFIG: gig config check refused it; nothing installed"

# cfg PATH: one scalar from gig.yaml, refused unless it is a plain token
# (each one reaches a command line below).
cfg() {
  local v
  v="$(yq e "$1" "$GIG_CONFIG")" || die 1 "$GIG_CONFIG: cannot read $1"
  if ! [[ $v =~ $SAFE_RE ]] || [ "$v" = null ]; then die 1 "$GIG_CONFIG: $1 is missing or not a plain value (got: '$v')"; fi
  printf '%s\n' "$v"
}
CFG_USER="$(cfg .host.user)"
POOL="$(cfg .host.pool)"
POOL_SIZE="$(cfg .host.grant.pool_size)"
MEMORY="$(cfg .host.grant.memory)"
CPU="$(cfg .host.grant.cpu)"
INSTANCES="$(cfg .host.grant.instances)"
GARM_VERSION="$(cfg .pins.garm)"
PROVIDER_VERSION="$(cfg .pins.garm_provider_incus)"
[ "$CFG_USER" = "$SERVICE_USER" ] || die 1 "$GIG_CONFIG: host.user is '$CFG_USER'; this role makes the service user '$SERVICE_USER' (ruled on heavy-duty/gig#11)"

# Every pin is checked against ./checksums before any download.
recorded_sha garm-linux-amd64.tgz "$GARM_VERSION" >/dev/null
recorded_sha garm-cli-linux-amd64.tgz "$GARM_VERSION" >/dev/null
recorded_sha garm-provider-incus-linux-amd64.tgz "$PROVIDER_VERSION" >/dev/null
fetch garm-linux-amd64.tgz "$GARM_VERSION" "$GARM_URL"
fetch garm-cli-linux-amd64.tgz "$GARM_VERSION" "$GARM_URL"
fetch garm-provider-incus-linux-amd64.tgz "$PROVIDER_VERSION" "$PROVIDER_URL"
unpack garm-linux-amd64.tgz garm
unpack garm-cli-linux-amd64.tgz garm-cli
unpack garm-provider-incus-linux-amd64.tgz garm-provider-incus

# box: on PATH and new enough for `box grant --service` with pool and caps.
command -v box >/dev/null 2>&1 || die 1 "box is not on PATH; the grant is box's (HOST=yes installs it)"
BOX_VERSION="$(box version 2>/dev/null | awk '{ print $2; exit }')"
if ! [[ $BOX_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] ||
  [ "$(printf '%s\n%s\n' "$BOX_FLOOR" "$BOX_VERSION" | sort -V | head -n1)" != "$BOX_FLOOR" ]; then
  die 1 "box ${BOX_VERSION:-(unknown)} is older than $BOX_FLOOR, which 'box grant --service --pool --memory --cpu --instances' needs"
fi

# An existing gig account is adopted only if it is a no-login system account.
if getent passwd "$SERVICE_USER" >/dev/null; then
  sys_uid_max="$(awk '$1 == "SYS_UID_MAX" { print $2; exit }' /etc/login.defs 2>/dev/null || true)"
  [[ $sys_uid_max =~ ^[0-9]+$ ]] || sys_uid_max=999
  uid="$(getent passwd "$SERVICE_USER" | cut -d: -f3)"
  shell="$(getent passwd "$SERVICE_USER" | cut -d: -f7)"
  [ "$uid" -le "$sys_uid_max" ] || die 1 "user $SERVICE_USER exists with uid $uid, above SYS_UID_MAX $sys_uid_max: not a system account; refusing to adopt it"
  case "$(basename -- "$shell")" in
    nologin | false) ;;
    *) die 1 "user $SERVICE_USER exists with login shell $shell; refusing to adopt it (a service account has nologin or false)" ;;
  esac
  if id -nG "$SERVICE_USER" | tr ' ' '\n' | grep -qx incus-admin; then
    die 1 "$SERVICE_USER is in incus-admin; remove it (gpasswd -d $SERVICE_USER incus-admin) — a service in incus-admin cannot be fenced"
  fi
fi
log "verified: gig.yaml, box $BOX_VERSION, garm $GARM_VERSION, garm-cli $GARM_VERSION, garm-provider-incus $PROVIDER_VERSION"

# --- phase 2: converge the host ----------------------------------------------

[ "$(id -u)" -eq 0 ] || die 1 "must run as root"

# place SRC DEST MODE OWNER:GROUP — replace DEST only when it differs; sets
# PLACED=1 when it wrote. Every step is checked: callers need no || true.
PLACED=0
place() {
  PLACED=0
  if ! cmp -s -- "$1" "$2"; then
    install -m "$3" -o "${4%:*}" -g "${4#*:}" -T -- "$1" "$2" || die 1 "cannot install $2"
    log "placed $2"
    PLACED=1
    return 0
  fi
  chmod "$3" -- "$2" || die 1 "cannot chmod $2"
  chown "$4" -- "$2" || die 1 "cannot chown $2"
}
# slot PATH OWNER:GROUP — an empty 0600 file, created once and never touched.
slot() {
  if [ ! -e "$1" ] && [ ! -L "$1" ]; then
    install -m 0600 -o "${2%:*}" -g "${2#*:}" /dev/null "$1"
    log "created empty slot $1"
  fi
}
systemd_up() { [ -d /run/systemd/system ]; }

# The service user, BEFORE the grant (box grant needs the user).
if ! getent passwd "$SERVICE_USER" >/dev/null; then
  useradd --system --user-group --no-create-home --home-dir /nonexistent \
    --shell /usr/sbin/nologin "$SERVICE_USER"
  log "created system user $SERVICE_USER"
fi

# The grant, BEFORE garm can start: a service reads its groups once, and one
# reaching incus-user before the grant makes an unhardened project
# (heavy-duty/box#281). box converges it on every run.
box grant --service "$SERVICE_USER" --pool "$POOL" --pool-size "$POOL_SIZE" \
  --memory "$MEMORY" --cpu "$CPU" --instances "$INSTANCES"

if [ "$YQ_PLACE" -eq 1 ]; then
  place "$WORK/bin/yq" /usr/local/bin/yq 0755 root:root
fi

# gig: its own installer, which does nothing when this version is current.
bash "$SRC/install.sh" --from "$GIG_TARBALL"

BIN_CHANGED=0
place "$WORK/new/garm" /usr/local/bin/garm 0755 root:root
BIN_CHANGED=$((BIN_CHANGED | PLACED))
place "$WORK/new/garm-cli" /usr/local/bin/garm-cli 0755 root:root
install -d -m 0755 -o root -g root /opt/garm /opt/garm/providers.d
place "$WORK/new/garm-provider-incus" /opt/garm/providers.d/garm-provider-incus 0755 root:root
BIN_CHANGED=$((BIN_CHANGED | PLACED))

install -d -m 0750 -o "$SERVICE_USER" -g "$SERVICE_USER" /etc/garm /var/lib/garm /var/lib/gig
chmod 0750 /etc/garm /var/lib/garm /var/lib/gig
chown "$SERVICE_USER:$SERVICE_USER" /etc/garm /var/lib/garm /var/lib/gig
slot /etc/garm/app-key.pem "$SERVICE_USER:$SERVICE_USER"

# garm.service: installed, NOT enabled — gig's engine enables it once it has
# rendered /etc/garm/config.toml. The grant above ran before this unit exists.
cat >"$WORK/garm.service" <<EOF
[Unit]
Description=garm, gig's runner manager (installed by rig-templates gig-server)
Documentation=https://github.com/heavy-duty/gig
# The box grant for $SERVICE_USER ran before this unit was installed
# (gig-server/install.sh); incus-user must be up for the provider's socket.
After=network-online.target incus.service incus-user.service
Wants=network-online.target
ConditionPathExists=/etc/garm/config.toml

[Service]
User=$SERVICE_USER
Group=$SERVICE_USER
ExecStart=/usr/local/bin/garm -config /etc/garm/config.toml
Restart=always
RestartSec=5
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=/var/lib/garm /etc/garm

[Install]
WantedBy=multi-user.target
EOF
place "$WORK/garm.service" /etc/systemd/system/garm.service 0644 root:root
if [ "$PLACED" -eq 1 ] && systemd_up; then
  systemctl daemon-reload
fi
# The hourly bake watcher (heavy-duty/gig#33): installed, NOT enabled. The
# operator enables the timer after the first manual bake (README).
cat >"$WORK/gig-bake-watch.service" <<EOF
[Unit]
Description=gig bake --if-stale: rebake goldens whose inputs moved (rig-templates gig-server)
Documentation=https://github.com/heavy-duty/gig
After=network-online.target incus.service incus-user.service
Wants=network-online.target

[Service]
Type=oneshot
User=$SERVICE_USER
Group=$SERVICE_USER
Environment=HOME=/var/lib/gig
ExecStart=/usr/local/bin/gig bake --if-stale
EOF
cat >"$WORK/gig-bake-watch.timer" <<'EOF'
[Unit]
Description=Hourly gig bake --if-stale (rig-templates gig-server)

[Timer]
OnCalendar=hourly
RandomizedDelaySec=5m
Persistent=true

[Install]
WantedBy=timers.target
EOF
UNITS_CHANGED=0
place "$WORK/gig-bake-watch.service" /etc/systemd/system/gig-bake-watch.service 0644 root:root
UNITS_CHANGED=$((UNITS_CHANGED | PLACED))
place "$WORK/gig-bake-watch.timer" /etc/systemd/system/gig-bake-watch.timer 0644 root:root
UNITS_CHANGED=$((UNITS_CHANGED | PLACED))
# The 5-minute doctor tick (heavy-duty/gig#7, ruling on heavy-duty/gig#40):
# ONE root unit. gig doctor reads the host, delivers alarms from the root-only
# notify.env and drops to gig itself (runuser) for its project. Installed,
# NOT enabled: the operator enables it once notify.env is filled (README).
install -d -m 0755 -o root -g root /var/lib/gig-doctor
cat >"$WORK/gig-doctor.service" <<'EOF'
[Unit]
Description=gig doctor: sweep, readings, alarms, heartbeat (rig-templates gig-server)
Documentation=https://github.com/heavy-duty/gig
After=network-online.target incus.service incus-user.service garm.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/gig doctor
EOF
cat >"$WORK/gig-doctor.timer" <<'EOF'
[Unit]
Description=gig doctor every 5 minutes (rig-templates gig-server)

[Timer]
OnCalendar=*:0/5
Persistent=true

[Install]
WantedBy=timers.target
EOF
place "$WORK/gig-doctor.service" /etc/systemd/system/gig-doctor.service 0644 root:root
UNITS_CHANGED=$((UNITS_CHANGED | PLACED))
place "$WORK/gig-doctor.timer" /etc/systemd/system/gig-doctor.timer 0644 root:root
UNITS_CHANGED=$((UNITS_CHANGED | PLACED))
if [ "$UNITS_CHANGED" -eq 1 ] && systemd_up; then
  systemctl daemon-reload
fi
# A pin bump replaces a running garm's binaries: restart it if it runs.
if [ "$BIN_CHANGED" -eq 1 ] && systemd_up; then
  systemctl try-restart garm.service
fi

printf '[Journal]\nSystemMaxUse=2G\n' >"$WORK/journald.conf"
install -d -m 0755 -o root -g root /etc/systemd/journald.conf.d
place "$WORK/journald.conf" /etc/systemd/journald.conf.d/gig.conf 0644 root:root
if [ "$PLACED" -eq 1 ] && systemd_up; then
  systemctl try-restart systemd-journald || log "journald restart failed; the cap applies at its next start"
fi

# gig.yaml LAST among the writes: it names pins the binaries above now
# match, so a failure earlier never leaves a config ahead of its host.
install -d -m 0755 -o root -g root /etc/gig
slot /etc/gig/notify.env root:root
place "$GIG_CONFIG" /etc/gig/gig.yaml 0644 root:root

# gig's two halves (heavy-duty/gig#19): box's firewall drop-in as root, then
# gig's profiles in gig's project as gig.
if [ "${GIG_SKIP_HOST_APPLY:-}" = "1" ]; then
  log "GIG_SKIP_HOST_APPLY=1 — skipping gig host apply (both halves)"
else
  gig host apply --root /etc/gig/gig.yaml
  (cd / && runuser -u "$SERVICE_USER" -- gig host apply /etc/gig/gig.yaml)
fi

log "converged: gig $(gig version), garm $GARM_VERSION, provider $PROVIDER_VERSION; slots to fill: /etc/garm/app-key.pem, /etc/gig/notify.env"
