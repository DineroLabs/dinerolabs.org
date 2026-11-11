#!/usr/bin/env python3
"""Exercise the Python snippets shipped inside the standalone install.sh."""

from __future__ import annotations

import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


INSTALLER = (Path(__file__).resolve().parents[1] / "install.sh").read_text()


def python_after(marker: str) -> str:
    start = INSTALLER.index(marker)
    start = INSTALLER.index("<<'PYEOF'\n", start) + len("<<'PYEOF'\n")
    end = INSTALLER.index("\nPYEOF", start)
    return INSTALLER[start:end]


class InstallerSnapshotTest(unittest.TestCase):
    def setUp(self) -> None:
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        self.manifest = self.root / "manifest.json"
        self.metadata_script = python_after('if ! metadata="$(python3 -')

    def publisher_manifest(self, *, height: int = 148375,
                           generated_at: str | None = None) -> dict:
        generated_at = generated_at or datetime.datetime.now(
            datetime.timezone.utc
        ).strftime("%Y%m%dT%H%M%SZ")
        return {
            "network": "mainnet",
            "format_version": 5,
            "generated_at": generated_at,
            "snapshot": {
                "snapshot_file": "snapshot.dat",
                "height": height,
                "bytes": 68_086_356,
                "sha256": "a" * 64,
            },
        }

    def check_metadata(self, manifest: dict, minimum_height: int = 148375,
                       profile: str = "legacy") -> subprocess.CompletedProcess[str]:
        self.manifest.write_text(json.dumps(manifest))
        return subprocess.run(
            ["python3", "-", str(self.manifest), str(minimum_height), profile],
            input=self.metadata_script, text=True, capture_output=True,
            check=False,
        )

    def test_current_old_mirror_refused_and_release_base_accepted(self) -> None:
        old = self.publisher_manifest(
            height=128475, generated_at="20261012T043837Z"
        )
        self.assertNotEqual(self.check_metadata(old).returncode, 0)
        self.assertNotEqual(self.check_metadata(
            self.publisher_manifest(height=128475)
        ).returncode, 0)
        wrong_profile = self.publisher_manifest()
        wrong_profile["format_version"] = 6
        wrong_profile["snapshot_profile"] = "compact"
        self.assertNotEqual(self.check_metadata(wrong_profile).returncode, 0)
        fresh = self.check_metadata(self.publisher_manifest())
        self.assertEqual(fresh.returncode, 0, fresh.stderr)
        self.assertEqual(fresh.stdout.split("\t")[1], "148375")

    def test_manifest_name_is_normalized_after_signature_verification(self) -> None:
        original = self.publisher_manifest()
        source = self.root / "signed-original.json"
        runtime = self.root / "runtime.json"
        source.write_text(json.dumps(original))
        signed_bytes = source.read_bytes()
        normalization = python_after(
            'if ! python3 - "$work/manifest.json" "$work/runtime.manifest.json"'
        )
        result = subprocess.run(
            ["python3", "-", str(source), str(runtime), "dinero-assumeutxo-live.dat"],
            input=normalization, text=True, capture_output=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(source.read_bytes(), signed_bytes)
        normalized = json.loads(runtime.read_text())
        self.assertEqual(normalized["snapshot"]["snapshot_file"], "dinero-assumeutxo-live.dat")
        normalized["snapshot"]["snapshot_file"] = "snapshot.dat"
        self.assertEqual(normalized, original)
        self.assertIn('mv "$work/manifest.sig" "$snapshot_out.publisher.manifest.sig"', INSTALLER)

    def test_full_v6_mirror_requires_full_profile(self) -> None:
        marker = "release_uses_full_v6() {"
        start = INSTALLER.index(marker)
        end = INSTALLER.index("\n}", start) + 2
        function = INSTALLER[start:end]
        def has_full_v6(tag: str) -> bool:
            result = subprocess.run(
                ["bash", "-c", function + '\nrelease_uses_full_v6 "$1"', "_", tag],
                text=True, capture_output=True, check=False,
            )
            return result.returncode == 0
        self.assertFalse(has_full_v6("v8.2.2"))
        self.assertTrue(has_full_v6("v8.2.3"))
        self.assertTrue(has_full_v6("v8.2.4"))
        self.assertFalse(has_full_v6("v8.2.3-rc1"))
        full = self.publisher_manifest(height=150521)
        full["format_version"] = 6
        full["snapshot_profile"] = "full"
        self.assertEqual(self.check_metadata(full, 150521, "full-v6").returncode, 0)
        self.assertNotEqual(self.check_metadata(full, 150521, "legacy").returncode, 0)
        full["snapshot_profile"] = "compact"
        self.assertNotEqual(self.check_metadata(full, 150521, "full-v6").returncode, 0)
        self.assertIn('/snapshot/full-v6', INSTALLER)
        pattern = re.search(r"^SNAPSHOT_PATTERN='([^']+)'$", INSTALLER, re.MULTILINE)
        self.assertIsNotNone(pattern)
        self.assertIsNotNone(re.fullmatch(pattern.group(1), "dinero-assumeutxo-150521-v6-full.dat"))
        self.assertIsNone(re.fullmatch(pattern.group(1), "dinero-assumeutxo-150521-v6-compact.dat"))

    def test_full_v6_release_selects_full_asset_even_with_newer_legacy_asset(self) -> None:
        discovery = python_after('python3 - "$RELEASES_JSON" >"$PICK"')
        assets = [
            {"name": "dinero-core-8.2.3-linux-x86_64.tar.gz", "browser_download_url": "https://example.test/core"},
            {"name": "dinero-assumeutxo-150521-v6-full.dat", "browser_download_url": "https://example.test/full"},
            {"name": "dinero-assumeutxo-150700-v5.dat", "browser_download_url": "https://example.test/legacy"},
        ]
        releases = self.root / "releases.json"
        releases.write_text(json.dumps([{
            "tag_name": "v8.2.3", "draft": False, "prerelease": False, "assets": assets,
        }]))
        env = os.environ.copy()
        for key in ("CORE_PATTERN", "CLI_PATTERN", "SNAPSHOT_PATTERN"):
            match = re.search(r"^" + key + r"='([^']+)'$", INSTALLER, re.MULTILINE)
            self.assertIsNotNone(match)
            env[key] = match.group(1)
        env["INCLUDE_PRERELEASE"] = "0"
        result = subprocess.run(
            ["python3", "-", str(releases)], input=discovery,
            text=True, capture_output=True, check=False, env=env,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[7], "dinero-assumeutxo-150521-v6-full.dat")

    def test_release_fallback_requires_matching_payload_and_manifest(self) -> None:
        payload = self.root / "dinero-assumeutxo-148375-v5.dat"
        payload.write_bytes(b"snapshot payload")
        digest = hashlib.sha256(payload.read_bytes()).hexdigest()
        manifest = self.publisher_manifest()
        manifest["snapshot"].update(
            snapshot_file=payload.name, bytes=payload.stat().st_size, sha256=digest
        )
        sidecar = self.root / (payload.name + ".manifest.json")
        sidecar.write_text(json.dumps(manifest))
        check = python_after(
            'python3 - "$SNAP_PATH" "$SNAP_MANIFEST" "$SNAP_HEIGHT" "$SNAP_PROFILE"'
        )
        def run() -> subprocess.CompletedProcess[str]:
            return subprocess.run(
                ["python3", "-", str(payload), str(sidecar), "148375", "legacy"],
                input=check, text=True, capture_output=True, check=False,
            )
        self.assertEqual(run().returncode, 0)
        manifest["snapshot"]["snapshot_file"] = "snapshot.dat"
        sidecar.write_text(json.dumps(manifest))
        self.assertNotEqual(run().returncode, 0)
        manifest["snapshot"]["snapshot_file"] = payload.name
        manifest["snapshot"]["sha256"] = "0" * 64
        sidecar.write_text(json.dumps(manifest))
        self.assertNotEqual(run().returncode, 0)

    def test_full_v6_release_fallback_refuses_compact_profile(self) -> None:
        payload = self.root / "dinero-assumeutxo-150521-v6-full.dat"
        payload.write_bytes(b"full-v6 snapshot payload")
        manifest = self.publisher_manifest(height=150521)
        manifest["format_version"] = 6
        manifest["snapshot_profile"] = "full"
        manifest["snapshot"].update(
            snapshot_file=payload.name,
            bytes=payload.stat().st_size,
            sha256=hashlib.sha256(payload.read_bytes()).hexdigest(),
        )
        sidecar = self.root / (payload.name + ".manifest.json")
        checker = python_after(
            'python3 - "$SNAP_PATH" "$SNAP_MANIFEST" "$SNAP_HEIGHT" "$SNAP_PROFILE"'
        )
        def run() -> subprocess.CompletedProcess[str]:
            return subprocess.run(
                ["python3", "-", str(payload), str(sidecar), "150521", "full-v6"],
                input=checker, text=True, capture_output=True, check=False,
            )
        sidecar.write_text(json.dumps(manifest))
        self.assertEqual(run().returncode, 0)
        manifest["snapshot_profile"] = "compact"
        sidecar.write_text(json.dumps(manifest))
        self.assertNotEqual(run().returncode, 0)

    def test_release_fallback_refuses_missing_either_asset_digest(self) -> None:
        marker = "snapshot_release_pair_has_digests() {"
        start = INSTALLER.index(marker)
        end = INSTALLER.index("\n}", start) + 2
        function = INSTALLER[start:end]
        self.assertIn(
            'snapshot_release_pair_has_digests "$SNAP_DIGEST" "$SNAP_MANIFEST_DIGEST"',
            INSTALLER,
        )
        valid = "sha256:" + "a" * 64
        def accepts(payload_digest: str, manifest_digest: str) -> bool:
            result = subprocess.run(
                ["bash", "-c", function + '\nsnapshot_release_pair_has_digests "$1" "$2"',
                 "_", payload_digest, manifest_digest],
                text=True, capture_output=True, check=False,
            )
            return result.returncode == 0
        self.assertTrue(accepts(valid, valid))
        self.assertFalse(accepts("-", valid))
        self.assertFalse(accepts(valid, "-"))
        self.assertFalse(accepts("a" * 64, valid))
        self.assertFalse(accepts(valid, "sha256:" + "0" * 63))


if __name__ == "__main__":
    unittest.main()
