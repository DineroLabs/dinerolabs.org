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
                       release_name: str = "dinero-assumeutxo-148375-v5.dat") -> subprocess.CompletedProcess[str]:
        self.manifest.write_text(json.dumps(manifest))
        return subprocess.run(
            ["python3", "-", str(self.manifest), str(minimum_height), release_name],
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
            'python3 - "$SNAP_PATH" "$SNAP_MANIFEST" "$SNAP_HEIGHT"'
        )
        def run() -> subprocess.CompletedProcess[str]:
            return subprocess.run(
                ["python3", "-", str(payload), str(sidecar), "148375"],
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

    def test_newest_full_v6_release_snapshot_is_selected(self) -> None:
        """A fresh installer must not fall back to V5 when V6-full is present."""
        release = self.root / "releases.json"
        names = [
            "dinero-linux-x86_64-8.2.3.tar.gz",
            "dinero-assumeutxo-148375-v5.dat",
            "dinero-assumeutxo-148375-v5.dat.manifest.json",
            "dinero-assumeutxo-152700-v6-full.dat",
            "dinero-assumeutxo-152700-v6-full.dat.manifest.json",
            "dinero-assumeutxo-153999-v6-bad.dat",
        ]
        release.write_text(json.dumps([{
            "tag_name": "v8.2.3", "draft": False, "prerelease": False,
            "assets": [{
                "name": name,
                "browser_download_url": f"https://example.invalid/{name}",
                "digest": "sha256:" + "a" * 64,
            } for name in names],
        }]))
        def assignment(name: str) -> str:
            match = re.search(rf"^{name}='([^']+)'$", INSTALLER, re.MULTILINE)
            self.assertIsNotNone(match)
            return match.group(1)
        env = os.environ | {
            "CORE_PATTERN": assignment("CORE_PATTERN"),
            "CLI_PATTERN": assignment("CLI_PATTERN"),
            "SNAPSHOT_PATTERN": assignment("SNAPSHOT_PATTERN"),
            "INCLUDE_PRERELEASE": "0",
        }
        selection = python_after('python3 - "$RELEASES_JSON" >"$PICK"')
        result = subprocess.run(
            ["python3", "-", str(release)], input=selection, env=env,
            text=True, capture_output=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        fields = result.stdout.splitlines()
        self.assertEqual(fields[0], "v8.2.3")
        self.assertEqual(fields[7], "dinero-assumeutxo-152700-v6-full.dat")
        self.assertEqual(
            fields[10], "dinero-assumeutxo-152700-v6-full.dat.manifest.json"
        )

    def test_full_v6_uses_signed_full_mirrors_and_admits_only_full_profile(self) -> None:
        start = INSTALLER.index("default_snapshot_mirrors() {")
        end = INSTALLER.index("\n}", start) + 2
        function = INSTALLER[start:end]
        def mirrors(name: str) -> list[str]:
            result = subprocess.run(
                ["bash", "-c", function + '\ndefault_snapshot_mirrors "$1"', "_", name],
                text=True, capture_output=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout.split()
        self.assertEqual(len(mirrors("dinero-assumeutxo-152700-v6-full.dat")), 3)
        self.assertTrue(all(
            url.endswith("/snapshot/full-v6")
            for url in mirrors("dinero-assumeutxo-152700-v6-full.dat")
        ))
        self.assertTrue(all(
            url.endswith("/snapshot")
            for url in mirrors("dinero-assumeutxo-148375-v5.dat")
        ))
        full = self.publisher_manifest(height=152700)
        full.update(format_version=6, snapshot_profile="full")
        full_name = "dinero-assumeutxo-152700-v6-full.dat"
        accepted = self.check_metadata(
            full, minimum_height=152700, release_name=full_name
        )
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        self.assertEqual(accepted.stdout.split("\t")[1], "152700")
        for profile in ("compact", "legacy", None):
            invalid = dict(full, snapshot_profile=profile)
            self.assertNotEqual(
                self.check_metadata(
                    invalid, minimum_height=152700, release_name=full_name
                ).returncode,
                0,
            )
        self.assertNotEqual(
            self.check_metadata(full, minimum_height=148375).returncode, 0,
            "an old release must not ingest a full-v6 mirror by accident",
        )
        self.assertIn('openssl pkeyutl -verify -pubin -inkey "$work/pub.pem" -rawin', INSTALLER)

    def test_full_v6_release_fallback_requires_exact_identity_and_payload(self) -> None:
        payload = self.root / "dinero-assumeutxo-152700-v6-full.dat"
        payload.write_bytes(b"full-v6 snapshot payload")
        digest = hashlib.sha256(payload.read_bytes()).hexdigest()
        manifest = self.publisher_manifest(height=152700)
        manifest.update(format_version=6, snapshot_profile="full")
        manifest["snapshot"].update(
            snapshot_file=payload.name,
            bytes=payload.stat().st_size,
            sha256=digest,
        )
        sidecar = self.root / (payload.name + ".manifest.json")
        check = python_after('python3 - "$SNAP_PATH" "$SNAP_MANIFEST" "$SNAP_HEIGHT"')
        def run() -> subprocess.CompletedProcess[str]:
            sidecar.write_text(json.dumps(manifest))
            return subprocess.run(
                ["python3", "-", str(payload), str(sidecar), "152700"],
                input=check, text=True, capture_output=True, check=False,
            )
        self.assertEqual(run().returncode, 0, run().stderr)
        manifest["snapshot"]["sha256"] = "0" * 64
        self.assertNotEqual(run().returncode, 0)
        manifest["snapshot"]["sha256"] = digest
        manifest["snapshot"]["snapshot_file"] = "snapshot.dat"
        self.assertNotEqual(run().returncode, 0)
        manifest["snapshot"]["snapshot_file"] = payload.name
        manifest["snapshot_profile"] = "compact"
        self.assertNotEqual(run().returncode, 0)

    def test_real_signed_full_v6_manifest_fixture(self) -> None:
        """The public full-v6 mirror's Ed25519 trio uses the installer's key."""
        fixture = Path(__file__).resolve().parent / "fixtures"
        manifest = fixture / "full-v6-h150521-manifest.json"
        signature = fixture / "full-v6-h150521-manifest.sig"
        body = json.loads(manifest.read_text())
        self.assertEqual(body["format_version"], 6)
        self.assertEqual(body["snapshot_profile"], "full")
        self.assertEqual(body["snapshot"]["height"], 150521)
        start = INSTALLER.index("-----BEGIN PUBLIC KEY-----")
        end = INSTALLER.index("-----END PUBLIC KEY-----", start)
        pem = self.root / "publisher.pem"
        pem.write_text(INSTALLER[start:end + len("-----END PUBLIC KEY-----")] + "\n")
        command = [
            "openssl", "pkeyutl", "-verify", "-pubin", "-inkey", str(pem),
            "-rawin", "-in", str(manifest), "-sigfile", str(signature),
        ]
        valid = subprocess.run(command, capture_output=True, text=True, check=False)
        self.assertEqual(valid.returncode, 0, valid.stderr)
        wrong = self.root / "wrong.sig"
        wrong.write_bytes(b"\0" * 64)
        command[-1] = str(wrong)
        invalid = subprocess.run(command, capture_output=True, text=True, check=False)
        self.assertNotEqual(invalid.returncode, 0)


if __name__ == "__main__":
    unittest.main()
