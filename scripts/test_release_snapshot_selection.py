#!/usr/bin/env python3
"""Keep the download page's snapshot choice aligned with the installer."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "verify_release_page", ROOT / "scripts" / "verify-release-page.py"
)
assert spec is not None and spec.loader is not None
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


class ReleaseSnapshotSelectionTest(unittest.TestCase):
    def test_full_v6_outweighs_legacy_snapshot(self) -> None:
        assets = {
            "dinero-assumeutxo-148375-v5.dat",
            "dinero-assumeutxo-152700-v6-full.dat",
            "dinero-assumeutxo-153999-v6-bad.dat",
        }
        selected = verifier.newest_snapshot_asset(assets)
        self.assertEqual(selected, "dinero-assumeutxo-152700-v6-full.dat")
        self.assertEqual(
            verifier.newest_snapshot_asset({"dinero-assumeutxo-148375-v5.dat"}),
            "dinero-assumeutxo-148375-v5.dat",
        )

    def test_selected_v6_snapshot_is_linked_on_candidate_page(self) -> None:
        snapshot = verifier.newest_snapshot_asset({
            "dinero-assumeutxo-148375-v5.dat",
            "dinero-assumeutxo-152700-v6-full.dat",
        })
        html = (ROOT / "index.html").read_text()
        self.assertIn(
            f"/releases/download/v8.2.3/{snapshot}?download=1", html
        )
        self.assertIn(
            f"/releases/download/v8.2.3/SHA256SUMS-assumeutxo-152700?download=1",
            html,
        )


if __name__ == "__main__":
    unittest.main()
