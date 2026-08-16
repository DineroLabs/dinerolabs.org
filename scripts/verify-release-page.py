#!/usr/bin/env python3
"""Verify that the public download page matches the latest stable v8 release."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import urllib.parse
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
INDEX = ROOT / "index.html"
INSTALLER = ROOT / "install.sh"
CORE_RELEASES_API = "https://api.github.com/repos/DineroLabs/dinero-v8/releases?per_page=10"


def fetch_json(url: str) -> object:
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "dinerolabs.org-release-verifier",
    }
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    with urllib.request.urlopen(
        urllib.request.Request(url, headers=headers), timeout=30
    ) as response:
        return json.load(response)


def assignment(script: str, name: str) -> str:
    match = re.search(rf"^{re.escape(name)}='([^']+)'$", script, re.MULTILINE)
    if not match:
        raise AssertionError(f"missing single-quoted {name} assignment")
    return match.group(1)


def main() -> None:
    html = INDEX.read_text()
    security_html = (ROOT / "security" / "index.html").read_text()
    installer = INSTALLER.read_text()
    releases = fetch_json(CORE_RELEASES_API)
    assert isinstance(releases, list)

    core_asset_re = re.compile(
        r"^(?:dinero-core-.*-linux-x86_64|dinero-linux-x86_64-.*)\.tar\.gz$"
    )

    stable = next(
        release
        for release in releases
        if not release.get("draft")
        and not release.get("prerelease")
        and any(
            core_asset_re.match(asset["name"])
            for asset in release.get("assets", [])
        )
    )
    native_release = next(
        release
        for release in releases
        if not release.get("draft")
        and not release.get("prerelease")
        and re.match(r"^dinerodpi-v[0-9]+\.[0-9]+\.[0-9]+$", release["tag_name"])
    )
    tag = stable["tag_name"]
    assets = {
        asset["name"]: (asset.get("digest") or "").removeprefix("sha256:")
        for asset in stable["assets"]
    }
    native_tag = native_release["tag_name"]
    native_version = native_tag.removeprefix("dinerodpi-v")
    native_assets = {
        asset["name"]: (asset.get("digest") or "").removeprefix("sha256:")
        for asset in native_release["assets"]
    }

    assert f"Dinero {tag} — current release" in html
    assert f"Download the current {tag}" in html

    retired_explorer_hosts = (
        "explorer." + "dinero-coin.com",
        "rpc." + "dinero-coin.com",
    )
    for host in retired_explorer_hosts:
        assert host not in html, f"retired explorer host remains in index.html: {host}"
        assert host not in security_html, (
            f"retired explorer host remains in security/index.html: {host}"
        )
    assert html.count("https://explorer.realmoneyforfreepeople.org/") == 4, (
        "expected the explorer URL in navigation, ticker action, footer, and JS"
    )
    assert 'const EXPLORER_RPC_URL = "https://rpc.realmoneyforfreepeople.org";' in html
    assert "https://explorer.realmoneyforfreepeople.org/" in security_html

    current_urls = re.findall(
        rf'href="(https://github\.com/DineroLabs/dinero-v8/releases/download/{re.escape(tag)}/[^\"]+)"',
        html,
    )
    linked_assets = [
        urllib.parse.unquote(url.rsplit("/", 1)[-1]) for url in current_urls
    ]
    missing = sorted(set(linked_assets) - assets.keys())
    assert not missing, f"download links reference missing {tag} assets: {missing}"
    version = tag.removeprefix("v")
    combined_linux = f"dinero-linux-x86_64-{version}.tar.gz"
    split_linux = f"dinero-core-{version}-linux-x86_64.tar.gz"
    linux_asset = combined_linux if combined_linux in assets else split_linux
    snapshot_assets = [
        name
        for name in assets
        if re.match(
            r"^(?:utxo-snapshot-[0-9]+|dinero-assumeutxo-[0-9]+-v[0-9]+)\.dat$",
            name,
        )
    ]
    assert snapshot_assets, f"{tag} has no snapshot asset"
    latest_snapshot = max(
        snapshot_assets,
        key=lambda name: int(re.search(r"(?:snapshot-|assumeutxo-)([0-9]+)", name).group(1)),
    )
    required_assets = {
        linux_asset,
        f"Dinero-Server-{version}-windows-x86_64-Setup.exe",
        f"Dinero-v{version}-macOS-arm64.dmg",
        f"Dinero-v{version}-macOS-arm64-qt.zip",
        f"Dinero-v{version}-macOS-x86_64.dmg",
        f"Dinero-v{version}-macOS-x86_64-qt.zip",
        f"dinero-v{version}-linux-x86_64.AppImage",
        f"dinero-v{version}-linux-x86_64-qt.tar.gz",
        f"dinero-qt-desktop_{version}-1_amd64.deb",
        f"dinero-operator-v{version}-macOS-arm64.tar.gz",
        f"dinero-operator-v{version}-macOS-x86_64.tar.gz",
        latest_snapshot,
    }
    absent_required = sorted(required_assets - assets.keys())
    assert not absent_required, f"{tag} is missing required release assets: {absent_required}"
    unlinked_required = sorted(required_assets - set(linked_assets))
    assert not unlinked_required, (
        f"public page does not link required {tag} assets: {unlinked_required}"
    )

    retired_v8_links = sorted(
        set(
            re.findall(
                r'https://github\.com/DineroLabs/dinero-v8/releases/download/(v8\.[^/\"]+)',
                html,
            )
        )
        - {tag}
    )
    assert not retired_v8_links, f"retired v8 download tags remain: {retired_v8_links}"

    assert f"DineroDPI macOS Native {native_version}" in html
    native_urls = re.findall(
        rf'href="(https://github\.com/DineroLabs/dinero-v8/releases/download/{re.escape(native_tag)}/[^\"]+)"',
        html,
    )
    native_linked_assets = [
        urllib.parse.unquote(url.rsplit("/", 1)[-1]) for url in native_urls
    ]
    missing_native = sorted(set(native_linked_assets) - native_assets.keys())
    assert not missing_native, (
        f"native download links reference missing {native_tag} assets: {missing_native}"
    )
    assert sorted(set(native_linked_assets)) == sorted(
        [
            f"DineroDPI-{native_version}.dmg",
            f"DineroDPI-{native_version}-macOS.zip",
        ]
    ), f"native download coverage is incomplete: {native_linked_assets}"

    hash_commands = re.findall(
        r"(?:certutil -hashfile ([^\s<]+) SHA256|shasum -a 256 ([^\s<]+))\s*\n"
        r"# Expected:\s*\n([0-9a-f]{64})",
        html,
    )
    checked_hashes: set[str] = set()
    checked_native_hashes = 0
    for certutil_filename, shasum_filename, expected in hash_commands:
        filename = certutil_filename or shasum_filename
        if filename.startswith("DineroDPI-"):
            assert filename in native_assets, (
                f"native hash command references missing asset: {filename}"
            )
            assert native_assets[filename] == expected, (
                f"displayed native SHA-256 is wrong: {filename}"
            )
            checked_native_hashes += 1
            continue
        assert filename in assets, f"hash command references missing asset: {filename}"
        assert assets[filename] == expected, f"displayed SHA-256 is wrong: {filename}"
        checked_hashes.add(filename)
    assert checked_hashes == required_assets, (
        f"displayed {tag} hash coverage differs from required assets: "
        f"missing={sorted(required_assets - checked_hashes)}, "
        f"extra={sorted(checked_hashes - required_assets)}"
    )
    assert checked_native_hashes == 1, (
        "expected one displayed native macOS asset hash, "
        f"found {checked_native_hashes}"
    )

    assert 'INCLUDE_PRERELEASE="${INCLUDE_PRERELEASE:-0}"' in installer
    patterns = [
        re.compile(assignment(installer, name))
        for name in ("CORE_PATTERN", "CLI_PATTERN", "SNAPSHOT_PATTERN")
    ]
    def selected_linux(pattern: re.Pattern[str]) -> str | None:
        matches = [name for name in assets if pattern.match(name)]
        return next(
            (name for name in matches if name.startswith("dinero-linux-x86_64-")),
            matches[0] if matches else None,
        )

    selected = [
        selected_linux(pattern) if index < 2 else latest_snapshot
        for index, pattern in enumerate(patterns)
    ]
    expected_cli = combined_linux if combined_linux in assets else f"dinero-cli-{version}-linux-x86_64.tar.gz"
    assert selected[0] == linux_asset, selected
    assert selected[1] == expected_cli, selected
    assert selected[2] == latest_snapshot, (
        f"installer does not select the newest {tag} snapshot: {selected}"
    )

    print(
        f"PASS: {tag}; {len(linked_assets)} valid release links; "
        f"{len(checked_hashes)} matching hashes; DineroDPI {native_tag} has "
        f"{len(set(native_linked_assets))} valid links and {checked_native_hashes} "
        "matching hash; installer selects core + CLI + snapshot"
    )


if __name__ == "__main__":
    main()
