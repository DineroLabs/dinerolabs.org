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
RELEASES_API = "https://api.github.com/repos/DineroLabs/dinero-v8/releases?per_page=10"


def fetch_releases() -> list[dict]:
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "dinerolabs.org-release-verifier",
    }
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    with urllib.request.urlopen(
        urllib.request.Request(RELEASES_API, headers=headers), timeout=30
    ) as response:
        return json.load(response)


def assignment(script: str, name: str) -> str:
    match = re.search(rf"^{re.escape(name)}='([^']+)'$", script, re.MULTILINE)
    if not match:
        raise AssertionError(f"missing single-quoted {name} assignment")
    return match.group(1)


def main() -> None:
    html = INDEX.read_text()
    installer = INSTALLER.read_text()
    releases = fetch_releases()

    stable = next(
        release
        for release in releases
        if not release.get("draft")
        and not release.get("prerelease")
        and any(
            re.match(r"^dinero-core-.*-linux-x86_64\.tar\.gz$", asset["name"])
            for asset in release.get("assets", [])
        )
    )
    tag = stable["tag_name"]
    assets = {
        asset["name"]: (asset.get("digest") or "").removeprefix("sha256:")
        for asset in stable["assets"]
    }

    assert f"Dinero {tag} — current consensus release" in html
    assert f"Download the current {tag}" in html

    current_urls = re.findall(
        rf'href="(https://github\.com/DineroLabs/dinero-v8/releases/download/{re.escape(tag)}/[^\"]+)"',
        html,
    )
    linked_assets = [
        urllib.parse.unquote(url.rsplit("/", 1)[-1]) for url in current_urls
    ]
    missing = sorted(set(linked_assets) - assets.keys())
    assert not missing, f"download links reference missing {tag} assets: {missing}"
    assert len(linked_assets) >= 20, (
        f"expected broad {tag} platform coverage, found {len(linked_assets)} links"
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

    hash_commands = re.findall(
        r"(?:certutil -hashfile ([^\s<]+) SHA256|shasum -a 256 ([^\s<]+))\s*\n"
        r"# Expected:\s*\n([0-9a-f]{64})",
        html,
    )
    checked_hashes = 0
    for certutil_filename, shasum_filename, expected in hash_commands:
        filename = certutil_filename or shasum_filename
        if filename.startswith("DineroDPI-"):
            continue
        assert filename in assets, f"hash command references missing asset: {filename}"
        assert assets[filename] == expected, f"displayed SHA-256 is wrong: {filename}"
        checked_hashes += 1
    assert checked_hashes == 10, (
        f"expected 10 displayed {tag} asset hashes, found {checked_hashes}"
    )

    assert 'INCLUDE_PRERELEASE="${INCLUDE_PRERELEASE:-0}"' in installer
    patterns = [
        re.compile(assignment(installer, name))
        for name in ("CORE_PATTERN", "CLI_PATTERN", "SNAPSHOT_PATTERN")
    ]
    selected = [
        next((name for name in assets if pattern.match(name)), None)
        for pattern in patterns
    ]
    version = tag.removeprefix("v")
    assert selected[0] == f"dinero-core-{version}-linux-x86_64.tar.gz", selected
    assert selected[1] == f"dinero-cli-{version}-linux-x86_64.tar.gz", selected
    assert selected[2] and re.match(
        r"^(utxo-snapshot-[0-9]+|dinero-assumeutxo-[0-9]+-v[0-9]+)\.dat$",
        selected[2],
    ), f"installer does not select the {tag} snapshot: {selected}"

    print(
        f"PASS: {tag}; {len(linked_assets)} valid release links; "
        f"{checked_hashes} matching hashes; installer selects core + CLI + snapshot"
    )


if __name__ == "__main__":
    main()
