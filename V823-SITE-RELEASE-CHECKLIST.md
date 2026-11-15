# v8.2.3 site release verification

The v8.2.3 GitHub release became public on 2026-11-15. The checks below were
completed against its final tagged assets before merging the site PR.

1. The final v8.2.3 release uses H153578 as its full-v6 primary. H153051 is the
   bundled lifecycle fallback; the page links the primary for fresh installs.
2. The public release has 68 assets. The page's 34 v8.2.3 links name 25
   distinct assets, all present in that release.
3. All 18 v8.2.3 package and snapshot SHA-256 values in `#verify` match the
   published GitHub asset digests. Five displayed hashes were updated after
   the exact-source tag workflows replaced the earlier draft assets. The
   snapshot card names H153578 full-v6.
4. Keep the Docker text at the latest independently verified published image
   version. It currently says 8.2.1; update it only after the new image exists.
5. `python3 scripts/test_installer_snapshot.py` passed 8/8,
   `python3 scripts/test_release_snapshot_selection.py` passed 2/2, and
   `python3 scripts/verify-release-page.py` passed against the public release
   with 34 valid links and 18 matching Core hashes. The installer tests cover
   a signed full-v6 publisher manifest, H153578-v6-full over the older V5
   release asset, and a digest-checked full-v6 release fallback.
6. Compare the installed download page with the candidate after deployment.

The independent DineroDPI Native 1.3.5 links stay unchanged. The Intel Ventura
Qt 6.5.3 assets retain their distinct names.
