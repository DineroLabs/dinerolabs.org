#!/usr/bin/env bash
# Dinero v8 one-command install for Ubuntu 24.04+ x86_64.
#
#   curl -fsSL https://dinerolabs.org/install.sh | sudo bash
#
# What this does (read before piping to sudo):
#   1. Verifies you're on Ubuntu 24.04+ x86_64 with root privileges
#   2. Queries the GitHub API for the latest Dinero v8 release
#      (includes pre-releases while v8 is still in rcN)
#   3. Downloads the Linux x86_64 dinerod + dinero-cli tarballs and verifies
#      each SHA256 against the digest published by GitHub for that asset
#   4. Installs both binaries to /usr/local/bin
#   5. Creates the dedicated dinero system user and /var/lib/dinero datadir
#   6. Writes /etc/systemd/system/dinero.service, enables, and starts it
#   7. If ufw is active, opens inbound P2P port 20999/tcp; does NOT expose
#      RPC port 20998 to the internet
#   8. Waits ~30s and reports node status (version, peer count, local addrs)
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
CORE_ASSET_PATTERN='^dinero-core-.*-linux-x86_64\.tar\.gz$'
CLI_ASSET_PATTERN='^dinero-cli-.*-linux-x86_64\.tar\.gz$'
P2P_PORT=20999
RPC_PORT=20998
SERVICE_UNIT="dinero.service"
SERVICE_USER="dinero"
DATADIR="/var/lib/dinero"
INSTALL_PREFIX="/usr/local/bin"

# Set INCLUDE_PRERELEASE=0 once a stable v8.0.0 ships and you want only stables.
INCLUDE_PRERELEASE="${INCLUDE_PRERELEASE:-1}"

# Safety guard: do not silently install an older tarball set if a future release
# publishes before Linux operator tarballs are ready. Operators can override
# intentionally, but the public one-liner should not drift users back.
ALLOW_OLDER_LINUX_TARBALLS="${ALLOW_OLDER_LINUX_TARBALLS:-0}"

# Override-able for mirrors / air-gapped installs (advanced).
RELEASE_API="${RELEASE_API:-https://api.github.com/repos/${RELEASE_REPO}/releases}"

# ---------------------------------------------------------------------------
# Pretty printers
# ---------------------------------------------------------------------------
note() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
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
  *) fail "Ubuntu 24.04+ required (detected: $OS_VER). For older Ubuntu, build from source or use the manual tarball release." ;;
esac

ARCH="$(dpkg --print-architecture 2>/dev/null || echo unknown)"
if [ "$ARCH" != "amd64" ]; then
  fail "x86_64 (amd64) required (detected: $ARCH). ARM64 Linux tarballs are not yet published."
fi

for cmd in curl python3 tar install systemctl sha256sum useradd id chown chmod; do
  command -v "$cmd" >/dev/null 2>&1 || fail "Missing required command: $cmd"
done

# ---------------------------------------------------------------------------
# Discover latest release + matching tarball assets
# ---------------------------------------------------------------------------
note "Querying GitHub for the latest Dinero v8 release"
TMP="$(mktemp -d -t dinero-install-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

RELEASES_JSON="$TMP/releases.json"
curl -fsSL -H 'Accept: application/vnd.github+json' \
  "${RELEASE_API}?per_page=10" -o "$RELEASES_JSON"

PICK="$TMP/pick.txt"
CORE_ASSET_PATTERN="$CORE_ASSET_PATTERN" \
CLI_ASSET_PATTERN="$CLI_ASSET_PATTERN" \
INCLUDE_PRERELEASE="$INCLUDE_PRERELEASE" \
python3 - "$RELEASES_JSON" >"$PICK" <<'PYEOF'
import json, os, re, sys
data = json.load(open(sys.argv[1]))
include_pre = os.environ.get("INCLUDE_PRERELEASE", "1") == "1"
core_pattern = re.compile(os.environ["CORE_ASSET_PATTERN"])
cli_pattern = re.compile(os.environ["CLI_ASSET_PATTERN"])

for rel in data:
    if rel.get("draft"):
        continue
    if rel.get("prerelease") and not include_pre:
        continue
    core = cli = None
    for asset in rel.get("assets", []):
        name = asset["name"]
        if core is None and core_pattern.match(name):
            core = asset
        if cli is None and cli_pattern.match(name):
            cli = asset
    if core and cli:
        print(rel["tag_name"])
        print(core["name"])
        print(core["browser_download_url"])
        print(core.get("digest", ""))
        print(cli["name"])
        print(cli["browser_download_url"])
        print(cli.get("digest", ""))
        sys.exit(0)

sys.exit("no matching Linux core + CLI tarballs on any recent release")
PYEOF

mapfile -t PICKED <"$PICK"
TAG="${PICKED[0]:-}"
CORE_ASSET_NAME="${PICKED[1]:-}"
CORE_ASSET_URL="${PICKED[2]:-}"
CORE_ASSET_DIGEST="${PICKED[3]:-}"
CLI_ASSET_NAME="${PICKED[4]:-}"
CLI_ASSET_URL="${PICKED[5]:-}"
CLI_ASSET_DIGEST="${PICKED[6]:-}"

[ -n "$TAG" ] && [ -n "$CORE_ASSET_URL" ] && [ -n "$CLI_ASSET_URL" ] || fail "Could not resolve release/assets from GitHub API"
note "Selected release: $TAG"
note "Core asset:       $CORE_ASSET_NAME"
note "CLI asset:        $CLI_ASSET_NAME"

LATEST_TAG="$(INCLUDE_PRERELEASE="$INCLUDE_PRERELEASE" python3 - "$RELEASES_JSON" <<'PYEOF'
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

if [ -n "$LATEST_TAG" ] && [ "$TAG" != "$LATEST_TAG" ] && [ "$ALLOW_OLDER_LINUX_TARBALLS" != "1" ]; then
  fail "Latest release is ${LATEST_TAG}, but the newest Linux tarball set found is ${TAG}. Refusing to install an older node. To intentionally install the older tarballs, rerun with ALLOW_OLDER_LINUX_TARBALLS=1."
fi

download_and_verify() {
  local name="$1"
  local url="$2"
  local digest="$3"
  local path="$TMP/$name"

  note "Downloading $name"
  curl -fsSL --retry 3 --connect-timeout 20 -o "$path" "$url"

  if [ -n "$digest" ]; then
    local expected="${digest#sha256:}"
    local actual
    actual="$(sha256sum "$path" | awk '{print $1}')"
    if [ "$expected" != "$actual" ]; then
      fail "SHA256 mismatch for $name — expected=$expected got=$actual"
    fi
    note "SHA256 verified for $name: $actual"
  else
    warn "GitHub did not return a digest for $name — proceeding WITHOUT hash verification (older API response shape)"
  fi

  printf '%s\n' "$path"
}

# ---------------------------------------------------------------------------
# Download, verify, and install binaries
# ---------------------------------------------------------------------------
CORE_PATH="$(download_and_verify "$CORE_ASSET_NAME" "$CORE_ASSET_URL" "$CORE_ASSET_DIGEST")"
CLI_PATH="$(download_and_verify "$CLI_ASSET_NAME" "$CLI_ASSET_URL" "$CLI_ASSET_DIGEST")"

EXTRACT_DIR="$TMP/extract"
mkdir -p "$EXTRACT_DIR"
tar -xzf "$CORE_PATH" -C "$EXTRACT_DIR"
tar -xzf "$CLI_PATH" -C "$EXTRACT_DIR"

DINEROD_PATH="$(find "$EXTRACT_DIR" -type f -name dinerod -perm -111 | head -1)"
CLI_PATH_EXTRACTED="$(find "$EXTRACT_DIR" -type f -name dinero-cli -perm -111 | head -1)"
[ -n "$DINEROD_PATH" ] || fail "Downloaded core tarball did not contain executable dinerod"
[ -n "$CLI_PATH_EXTRACTED" ] || fail "Downloaded CLI tarball did not contain executable dinero-cli"

note "Installing binaries to ${INSTALL_PREFIX}"
install -m 0755 "$DINEROD_PATH" "${INSTALL_PREFIX}/dinerod"
install -m 0755 "$CLI_PATH_EXTRACTED" "${INSTALL_PREFIX}/dinero-cli"

if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
  note "Creating ${SERVICE_USER} system user"
  useradd --system --home-dir "$DATADIR" --shell /usr/sbin/nologin "$SERVICE_USER"
fi

note "Preparing datadir ${DATADIR}"
install -d -m 0750 -o "$SERVICE_USER" -g "$SERVICE_USER" "$DATADIR"

note "Writing systemd unit ${SERVICE_UNIT}"
cat >"/etc/systemd/system/${SERVICE_UNIT}" <<EOF
[Unit]
Description=Dinero node
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
ExecStart=${INSTALL_PREFIX}/dinerod -datadir=${DATADIR}
Restart=on-failure
RestartSec=10
LimitNOFILE=65536
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=${DATADIR}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

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
note "Enabling and starting ${SERVICE_UNIT}"
systemctl enable --now "$SERVICE_UNIT"

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
note "Waiting 30s for dinerod to initialize and reach out to peers..."
sleep 30

note "Node status:"

VERSION_LINE="$(dinerod --version 2>/dev/null | grep -E '^(dinerod|version|commit)' | head -3 || true)"
if [ -n "$VERSION_LINE" ]; then
  while IFS= read -r line; do printf '  %s\n' "$line"; done <<<"$VERSION_LINE"
fi

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
  fleet. To check peer count later: dinero-cli -datadir=${DATADIR} getnetworkinfo

  Issues:   https://github.com/${RELEASE_REPO}/issues
────────────────────────────────────────────────────────────────────────────
MSG
