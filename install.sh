#!/usr/bin/env bash
# Dinero v8 one-command install for Ubuntu 24.04+ x86_64.
#
#   curl -fsSL https://dinerolabs.org/install.sh | sudo bash
#
# What this does (read before piping to sudo):
#   1. Verifies you're on Ubuntu 24.04+ x86_64 with root privileges
#   2. Queries the GitHub API for the latest Dinero v8 release (currently
#      includes pre-releases — v8 is still in rcN)
#   3. Downloads dinero-core_<version>_amd64.deb and verifies its SHA256
#      against the digest published by GitHub for that asset
#   4. Installs the .deb via apt (pulls dependencies automatically)
#   5. If ufw is active, opens inbound P2P port 20999/tcp; does NOT expose
#      RPC port 20998 to the internet
#   6. Enables and starts dinero.service via systemd
#   7. Waits ~30s and reports node status (version, peer count, local addrs)
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
ASSET_PATTERN='^dinero-core_.*_amd64\.deb$'
P2P_PORT=20999
RPC_PORT=20998
SERVICE_UNIT="dinero.service"

# Set INCLUDE_PRERELEASE=0 once a stable v8.0.0 ships and you want only stables.
INCLUDE_PRERELEASE="${INCLUDE_PRERELEASE:-1}"

# Safety guard: do not silently install an older Linux .deb when the current
# release has not published a Linux package yet. Operators can override this
# intentionally, but the public one-liner should not drift users back to an
# older release.
ALLOW_OLDER_LINUX_DEB="${ALLOW_OLDER_LINUX_DEB:-0}"

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
  *) fail "Ubuntu 24.04+ required (detected: $OS_VER). For older Ubuntu, build from source or wait for a backported .deb." ;;
esac

ARCH="$(dpkg --print-architecture 2>/dev/null || echo unknown)"
if [ "$ARCH" != "amd64" ]; then
  fail "x86_64 (amd64) required (detected: $ARCH). ARM64 Linux .deb is not yet published."
fi

for cmd in curl python3 dpkg apt-get systemctl sha256sum; do
  command -v "$cmd" >/dev/null 2>&1 || fail "Missing required command: $cmd"
done

# ---------------------------------------------------------------------------
# Discover latest release + matching .deb asset
# ---------------------------------------------------------------------------
note "Querying GitHub for the latest Dinero v8 release"
TMP="$(mktemp -d -t dinero-install-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

RELEASES_JSON="$TMP/releases.json"
curl -fsSL -H 'Accept: application/vnd.github+json' \
  "${RELEASE_API}?per_page=10" -o "$RELEASES_JSON"

# Parse with python3 (always present on Ubuntu base). Picks the first release
# whose assets contain a name matching $ASSET_PATTERN, skipping drafts (and
# pre-releases iff INCLUDE_PRERELEASE=0).
PICK="$TMP/pick.txt"
ASSET_PATTERN="$ASSET_PATTERN" \
INCLUDE_PRERELEASE="$INCLUDE_PRERELEASE" \
python3 - "$RELEASES_JSON" >"$PICK" <<'PYEOF'
import json, os, re, sys
data = json.load(open(sys.argv[1]))
include_pre = os.environ.get("INCLUDE_PRERELEASE", "1") == "1"
pattern = re.compile(os.environ["ASSET_PATTERN"])
for rel in data:
    if rel.get("draft"):
        continue
    if rel.get("prerelease") and not include_pre:
        continue
    for asset in rel.get("assets", []):
        if pattern.match(asset["name"]):
            print(rel["tag_name"])
            print(asset["name"])
            print(asset["browser_download_url"])
            print(asset.get("digest", ""))
            sys.exit(0)
sys.exit("no matching .deb asset on any recent release")
PYEOF

mapfile -t PICKED <"$PICK"
TAG="${PICKED[0]:-}"
ASSET_NAME="${PICKED[1]:-}"
ASSET_URL="${PICKED[2]:-}"
ASSET_DIGEST="${PICKED[3]:-}"

[ -n "$TAG" ] && [ -n "$ASSET_URL" ] || fail "Could not resolve release/asset from GitHub API"
note "Selected release: $TAG"
note "Asset:            $ASSET_NAME"

LATEST_TAG="$(python3 - "$RELEASES_JSON" <<'PYEOF'
import json, os, sys
data = json.load(open(sys.argv[1]))
include_pre = os.environ.get("INCLUDE_PRERELEASE", "1") == "1"
for rel in data:
    if rel.get("draft"):
        continue
    if rel.get("prerelease") and not include_pre:
        continue
    print(rel["tag_name"])
    break
PYEOF
)"

if [ -n "$LATEST_TAG" ] && [ "$TAG" != "$LATEST_TAG" ] && [ "$ALLOW_OLDER_LINUX_DEB" != "1" ]; then
  fail "Latest release is ${LATEST_TAG}, but the newest Linux .deb asset found is ${TAG}. Linux packaging for the current release is pending; refusing to install an older node. To intentionally install the older .deb, rerun with ALLOW_OLDER_LINUX_DEB=1."
fi

# ---------------------------------------------------------------------------
# Download + hash-verify
# ---------------------------------------------------------------------------
DEB_PATH="$TMP/$ASSET_NAME"
note "Downloading $ASSET_NAME"
curl -fsSL --retry 3 --connect-timeout 20 -o "$DEB_PATH" "$ASSET_URL"

if [ -n "$ASSET_DIGEST" ]; then
  EXPECTED="${ASSET_DIGEST#sha256:}"
  ACTUAL="$(sha256sum "$DEB_PATH" | awk '{print $1}')"
  if [ "$EXPECTED" != "$ACTUAL" ]; then
    fail "SHA256 mismatch — refusing to install. expected=$EXPECTED got=$ACTUAL"
  fi
  note "SHA256 verified: $ACTUAL"
else
  warn "GitHub did not return a digest for this asset — proceeding WITHOUT hash verification (older API response shape)"
fi

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
note "Installing $ASSET_NAME (apt will pull dependencies)"
DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y "$DEB_PATH"

# ---------------------------------------------------------------------------
# Firewall (ufw, if present and active)
# ---------------------------------------------------------------------------
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
  note "ufw is active — allowing inbound P2P port ${P2P_PORT}/tcp"
  ufw allow "${P2P_PORT}/tcp" >/dev/null || warn "ufw allow ${P2P_PORT}/tcp failed (non-fatal)"
  note "RPC port ${RPC_PORT} is intentionally NOT exposed to the internet"
  note "(RPC controls your wallet — only open it if you understand the implications)"
else
  note "ufw not active — skipping firewall config"
  note "If you run a different firewall, allow inbound ${P2P_PORT}/tcp for P2P connectivity"
fi

# ---------------------------------------------------------------------------
# systemd: enable + start
# ---------------------------------------------------------------------------
if ! systemctl list-unit-files "$SERVICE_UNIT" --no-legend 2>/dev/null | grep -q "^${SERVICE_UNIT}"; then
  fail "Expected systemd unit '${SERVICE_UNIT}' not found after install — check 'systemctl list-unit-files dinero*'"
fi

note "Enabling and starting ${SERVICE_UNIT}"
systemctl enable --now "$SERVICE_UNIT"

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
note "Waiting 30s for dinerod to initialize and reach out to peers..."
sleep 30

note "Node status:"

# The packaged-service install puts datadir at /var/lib/dinero, so dinero-cli
# must be told where to find the RPC cookie — bare `dinero-cli` looks in
# $HOME/.dinero and won't find it when run as root or any non-service user.
DATADIR=/var/lib/dinero

if command -v dinerod >/dev/null 2>&1; then
  # dinerod emits non-version log noise before the version line on some builds
  # ("[INFO] [AutoReg] Mining extras..."), so filter to lines that look like
  # version output rather than blindly taking the first line.
  VERSION_LINE="$(dinerod --version 2>/dev/null | grep -E '^(dinerod|version|commit)' | head -3 || true)"
  if [ -n "$VERSION_LINE" ]; then
    while IFS= read -r line; do printf '  %s\n' "$line"; done <<<"$VERSION_LINE"
  fi
fi

if command -v dinero-cli >/dev/null 2>&1; then
  INFO_FILE="$TMP/netinfo.json"
  if dinero-cli -datadir="$DATADIR" getnetworkinfo >"$INFO_FILE" 2>/dev/null; then
    python3 - "$INFO_FILE" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"  Subversion:   {d.get('subversion', d.get('version', 'unknown'))}")
print(f"  Connections:  {d.get('connections', 'unknown')}")
addrs = [a.get('address') for a in d.get('localaddresses', [])]
print(f"  Local addrs:  {addrs if addrs else 'none yet (will populate after a peer advertises your public address)'}")
PYEOF
  else
    warn "dinero-cli getnetworkinfo failed — daemon may still be initializing. Run 'systemctl status ${SERVICE_UNIT}' to check."
  fi
else
  warn "dinero-cli not on PATH after install — investigate manually"
fi

cat <<MSG

────────────────────────────────────────────────────────────────────────────
  Dinero ${TAG} installed and running as ${SERVICE_UNIT}.

  Useful commands:
    systemctl status ${SERVICE_UNIT}
    journalctl -u ${SERVICE_UNIT} -f
    dinero-cli -datadir=${DATADIR} getnetworkinfo
    dinero-cli -datadir=${DATADIR} getblockchaininfo

  Ports:
    P2P  ${P2P_PORT}/tcp  — open to internet (if you have a NAT, also forward this port)
    RPC  ${RPC_PORT}/tcp  — localhost only by default; do NOT expose

  Dinero is a young network. Your node helps it grow beyond the bootstrap
  fleet. To check peer count later: dinero-cli getnetworkinfo

  Issues:   https://github.com/${RELEASE_REPO}/issues
────────────────────────────────────────────────────────────────────────────
MSG
