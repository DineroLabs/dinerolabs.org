#!/usr/bin/env bash
# Dinero v8 one-command install for Ubuntu 24.04+ x86_64.
#
#   curl -fsSL https://dinerolabs.org/install.sh | sudo bash
#
# What this does (read before piping to sudo):
#   1. Verifies you're on Ubuntu 24.04+ x86_64 with root privileges
#   2. Queries the GitHub API for the latest Dinero v8 release (currently
#      includes pre-releases — v8 is still in rcN)
#   3. Downloads the headless Linux tarballs (dinero-core = daemon, dinero-cli)
#      and verifies each against the digest GitHub publishes for the asset
#   4. Installs dinerod + dinero-cli to /usr/local/bin
#   5. Creates the `dinero` system user + /var/lib/dinero datadir
#   6. FAST SYNC: if the release ships an AssumeUTXO snapshot, downloads it and
#      configures the node to bootstrap from it. The node becomes usable in
#      minutes, verifies forward to the tip, and BACKGROUND-VALIDATES the
#      pre-snapshot history — the snapshot is checked against a hash compiled
#      into the binary, so a tampered file is rejected (it falls back to a full
#      sync from genesis, never hangs). Set DINERO_FAST_SYNC=0 to force a full
#      validate-from-genesis sync.
#   7. Writes + enables a dinero.service systemd unit, starts it
#   8. If ufw is active, opens inbound P2P port 20999/tcp; never exposes RPC
#   9. Waits ~30s and reports node status (version, peer count, local addrs)
#
# Source:   https://github.com/DineroLabs/dinerolabs.org/blob/main/install.sh
# Releases: https://github.com/DineroLabs/dinero-v8/releases
# Network:  Dinero is a young network. Running a node helps it move from
#           bootstrap infrastructure toward broad community peer discovery.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
RELEASE_REPO="DineroLabs/dinero-v8"
CORE_PATTERN='^dinero-core-.*-linux-x86_64\.tar\.gz$'
CLI_PATTERN='^dinero-cli-.*-linux-x86_64\.tar\.gz$'
SNAPSHOT_PATTERN='^utxo-snapshot-[0-9]+\.dat$'
P2P_PORT=20999
RPC_PORT=20998
SERVICE_UNIT="dinero.service"
DATADIR=/var/lib/dinero
BINDIR=/usr/local/bin
RUN_USER=dinero

# Set INCLUDE_PRERELEASE=0 once a stable v8.0.0 ships and you want only stables.
INCLUDE_PRERELEASE="${INCLUDE_PRERELEASE:-1}"

# Fast sync via AssumeUTXO snapshot (default on). DINERO_FAST_SYNC=0 forces a
# full validate-from-genesis sync (no snapshot bootstrap).
DINERO_FAST_SYNC="${DINERO_FAST_SYNC:-1}"

# Override-able for mirrors / air-gapped installs (advanced).
RELEASE_API="${RELEASE_API:-https://api.github.com/repos/${RELEASE_REPO}/releases}"

# ---------------------------------------------------------------------------
# Pretty printers
# ---------------------------------------------------------------------------
note() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
fail() { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
note "Pre-flight checks"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  fail "Run as root: curl -fsSL https://dinerolabs.org/install.sh | sudo bash"
fi

if [ ! -r /etc/os-release ]; then
  fail "Cannot read /etc/os-release — unsupported platform"
fi
# shellcheck disable=SC1091
. /etc/os-release
OS_ID="${ID:-unknown}"
OS_VER="${VERSION_ID:-unknown}"

if [ "$OS_ID" != "ubuntu" ]; then
  fail "Ubuntu required (detected: $OS_ID). See https://github.com/${RELEASE_REPO}/releases for other platforms."
fi
case "$OS_VER" in
  24.04|24.10|25.04|25.10|26.04) : ;;
  *) fail "Ubuntu 24.04+ required (detected: $OS_VER). For older Ubuntu, build from source." ;;
esac

ARCH="$(dpkg --print-architecture 2>/dev/null || echo unknown)"
if [ "$ARCH" != "amd64" ]; then
  fail "x86_64 (amd64) required (detected: $ARCH). ARM64 Linux is not yet published."
fi

for cmd in curl python3 tar systemctl sha256sum install; do
  command -v "$cmd" >/dev/null 2>&1 || fail "Missing required command: $cmd"
done

# ---------------------------------------------------------------------------
# Discover latest release + its Linux tarball assets
# ---------------------------------------------------------------------------
note "Querying GitHub for the latest Dinero v8 release"
TMP="$(mktemp -d -t dinero-install-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

RELEASES_JSON="$TMP/releases.json"
curl -fsSL -H 'Accept: application/vnd.github+json' \
  "${RELEASE_API}?per_page=10" -o "$RELEASES_JSON"

# Pick the newest non-draft release (honoring INCLUDE_PRERELEASE) whose assets
# contain a Linux core tarball, and emit name/url/digest for each asset of
# interest (core, cli, snapshot). One line per field; "-" when absent.
PICK="$TMP/pick.txt"
CORE_PATTERN="$CORE_PATTERN" CLI_PATTERN="$CLI_PATTERN" \
SNAPSHOT_PATTERN="$SNAPSHOT_PATTERN" INCLUDE_PRERELEASE="$INCLUDE_PRERELEASE" \
python3 - "$RELEASES_JSON" >"$PICK" <<'PYEOF'
import json, os, re, sys
data = json.load(open(sys.argv[1]))
include_pre = os.environ.get("INCLUDE_PRERELEASE", "1") == "1"
core_re = re.compile(os.environ["CORE_PATTERN"])
cli_re = re.compile(os.environ["CLI_PATTERN"])
snap_re = re.compile(os.environ["SNAPSHOT_PATTERN"])

def find(assets, rx):
    for a in assets:
        if rx.match(a["name"]):
            return a
    return None

for rel in data:
    if rel.get("draft"):
        continue
    if rel.get("prerelease") and not include_pre:
        continue
    assets = rel.get("assets", [])
    core = find(assets, core_re)
    if not core:
        continue  # this release has no Linux core tarball; try older
    cli = find(assets, cli_re)
    snap = find(assets, snap_re)
    print(rel["tag_name"])
    for a in (core, cli, snap):
        if a:
            print(a["name"]); print(a["browser_download_url"]); print(a.get("digest", "") or "-")
        else:
            print("-"); print("-"); print("-")
    sys.exit(0)
sys.exit("no Dinero v8 release with a Linux core tarball found on the last 10 releases")
PYEOF

mapfile -t P <"$PICK"
TAG="${P[0]:-}"
CORE_NAME="${P[1]:-}";  CORE_URL="${P[2]:-}";  CORE_DIGEST="${P[3]:-}"
CLI_NAME="${P[4]:-}";   CLI_URL="${P[5]:-}";   CLI_DIGEST="${P[6]:-}"
SNAP_NAME="${P[7]:-}";  SNAP_URL="${P[8]:-}";  SNAP_DIGEST="${P[9]:-}"

[ -n "$TAG" ] && [ "$CORE_URL" != "-" ] || fail "Could not resolve a Linux release from the GitHub API"
note "Selected release: $TAG"

# ---------------------------------------------------------------------------
# Download + hash-verify + install a tarball binary
# ---------------------------------------------------------------------------
dl_verify() {  # <name> <url> <digest> <out>
  local name="$1" url="$2" digest="$3" out="$4"
  note "Downloading $name"
  curl -fsSL --retry 3 --connect-timeout 20 -o "$out" "$url"
  if [ -n "$digest" ] && [ "$digest" != "-" ]; then
    local expected="${digest#sha256:}"
    local actual; actual="$(sha256sum "$out" | awk '{print $1}')"
    [ "$expected" = "$actual" ] || fail "SHA256 mismatch for $name (expected $expected got $actual)"
    note "SHA256 verified: $actual"
  else
    warn "No digest from GitHub for $name — proceeding without hash verification"
  fi
}

install_tarball_bin() {  # <tarball> <binary-basename>
  local tarball="$1" binname="$2" stage; stage="$(mktemp -d)"
  tar -xzf "$tarball" -C "$stage"
  local found; found="$(find "$stage" -type f -name "$binname" | head -1)"
  [ -n "$found" ] || fail "Could not find $binname inside $tarball"
  install -m 0755 "$found" "$BINDIR/$binname"
  rm -rf "$stage"
  note "Installed $BINDIR/$binname"
}

note "Installing dinerod + dinero-cli to $BINDIR"
dl_verify "$CORE_NAME" "$CORE_URL" "$CORE_DIGEST" "$TMP/core.tgz"
install_tarball_bin "$TMP/core.tgz" "dinerod"
if [ "$CLI_URL" != "-" ]; then
  dl_verify "$CLI_NAME" "$CLI_URL" "$CLI_DIGEST" "$TMP/cli.tgz"
  install_tarball_bin "$TMP/cli.tgz" "dinero-cli"
else
  warn "Release $TAG has no dinero-cli tarball — installing daemon only"
fi

# ---------------------------------------------------------------------------
# System user + datadir
# ---------------------------------------------------------------------------
if ! id -u "$RUN_USER" >/dev/null 2>&1; then
  note "Creating system user '$RUN_USER'"
  useradd --system --home-dir "$DATADIR" --shell /usr/sbin/nologin "$RUN_USER"
fi
mkdir -p "$DATADIR"
chown -R "$RUN_USER:$RUN_USER" "$DATADIR"
chmod 0750 "$DATADIR"

FRESH_DATADIR=0
if [ ! -e "$DATADIR/blockchain" ] && [ ! -e "$DATADIR/blocks" ]; then
  FRESH_DATADIR=1
fi

# ---------------------------------------------------------------------------
# Fast sync: fetch the AssumeUTXO snapshot (only useful on a fresh datadir)
# ---------------------------------------------------------------------------
SNAPSHOT_LINE=""
if [ "$DINERO_FAST_SYNC" = "1" ] && [ "$SNAP_URL" != "-" ] && [ "$FRESH_DATADIR" = "1" ]; then
  SNAP_PATH="$DATADIR/$SNAP_NAME"
  dl_verify "$SNAP_NAME" "$SNAP_URL" "$SNAP_DIGEST" "$SNAP_PATH"
  chown "$RUN_USER:$RUN_USER" "$SNAP_PATH"
  SNAPSHOT_LINE="assumeutxo_snapshot=$SNAP_PATH"
  note "Fast sync enabled — node will bootstrap from $SNAP_NAME (verified against the binary's built-in trust anchor), then validate forward + in the background."
elif [ "$DINERO_FAST_SYNC" != "1" ]; then
  note "DINERO_FAST_SYNC=0 — full validate-from-genesis sync (no snapshot)"
elif [ "$FRESH_DATADIR" != "1" ]; then
  note "Existing datadir detected — skipping snapshot bootstrap (full node continues normally)"
else
  note "Release $TAG ships no snapshot — full validate-from-genesis sync"
fi

# ---------------------------------------------------------------------------
# Config (only create if absent — never clobber an operator's config)
# ---------------------------------------------------------------------------
CONF="$DATADIR/dinero.conf"
if [ ! -f "$CONF" ]; then
  note "Writing $CONF"
  {
    echo "# Dinero node config — written by install.sh ($TAG)"
    echo "listen=1"
    echo "rpcbind=127.0.0.1"
    echo "rpcallowip=127.0.0.1"
    [ -n "$SNAPSHOT_LINE" ] && echo "$SNAPSHOT_LINE"
  } > "$CONF"
  chown "$RUN_USER:$RUN_USER" "$CONF"
  chmod 0640 "$CONF"
else
  warn "$CONF already exists — leaving it unchanged"
  if [ -n "$SNAPSHOT_LINE" ] && ! grep -q '^assumeutxo_snapshot=' "$CONF"; then
    warn "To enable fast sync on this node, add to $CONF: $SNAPSHOT_LINE"
  fi
fi

# ---------------------------------------------------------------------------
# systemd unit
# ---------------------------------------------------------------------------
UNIT_PATH="/etc/systemd/system/$SERVICE_UNIT"
note "Writing $UNIT_PATH"
cat > "$UNIT_PATH" <<UNIT
[Unit]
Description=Dinero v8 node (dinerod)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$RUN_USER
Group=$RUN_USER
ExecStart=$BINDIR/dinerod -datadir=$DATADIR
Restart=on-failure
RestartSec=5
TimeoutStopSec=120
LimitNOFILE=8192

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload

# ---------------------------------------------------------------------------
# Firewall (ufw, if present and active)
# ---------------------------------------------------------------------------
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
  note "ufw is active — allowing inbound P2P port ${P2P_PORT}/tcp"
  ufw allow "${P2P_PORT}/tcp" >/dev/null || warn "ufw allow ${P2P_PORT}/tcp failed (non-fatal)"
  note "RPC port ${RPC_PORT} is intentionally NOT exposed to the internet"
else
  note "ufw not active — if you run a firewall, allow inbound ${P2P_PORT}/tcp for P2P"
fi

# ---------------------------------------------------------------------------
# Enable + start + verify
# ---------------------------------------------------------------------------
note "Enabling and starting ${SERVICE_UNIT}"
systemctl enable --now "$SERVICE_UNIT"

note "Waiting 30s for dinerod to initialize and reach out to peers..."
sleep 30

note "Node status:"
if command -v dinero-cli >/dev/null 2>&1; then
  INFO_FILE="$TMP/netinfo.json"
  if dinero-cli -datadir="$DATADIR" getnetworkinfo >"$INFO_FILE" 2>/dev/null; then
    python3 - "$INFO_FILE" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"  Subversion:   {d.get('subversion', d.get('version', 'unknown'))}")
print(f"  Connections:  {d.get('connections', 'unknown')}")
addrs = [a.get('address') for a in d.get('localaddresses', [])]
print(f"  Local addrs:  {addrs if addrs else 'none yet (populates after a peer advertises your public address)'}")
PYEOF
  else
    warn "dinero-cli getnetworkinfo failed — daemon may still be initializing. Check: systemctl status ${SERVICE_UNIT}"
  fi
fi

cat <<MSG

────────────────────────────────────────────────────────────────────────────
  Dinero ${TAG} installed and running as ${SERVICE_UNIT}.

  Useful commands:
    systemctl status ${SERVICE_UNIT}
    journalctl -u ${SERVICE_UNIT} -f
    dinero-cli -datadir=${DATADIR} getblockchaininfo

  Fast sync: ${SNAPSHOT_LINE:+enabled (AssumeUTXO bootstrap → forward + background validation)}${SNAPSHOT_LINE:-not active (full validate-from-genesis sync)}

  Ports:
    P2P  ${P2P_PORT}/tcp  — open to internet (forward this port if behind NAT)
    RPC  ${RPC_PORT}/tcp  — localhost only; do NOT expose

  Dinero is a young network. Your node helps it grow beyond the bootstrap
  fleet. Issues: https://github.com/${RELEASE_REPO}/issues
────────────────────────────────────────────────────────────────────────────
MSG
