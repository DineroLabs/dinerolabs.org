# v8.2.3 site candidate — local hold

This branch prepares the download page for the planned v8.2.3 release. A draft
PR can run checks early; do not merge or deploy it until the release is public
and the checks below pass.

1. Confirm that the final v8.2.3 release still uses H153578 as its full-v6
   primary. H153051 is the bundled lifecycle fallback; link the primary for
   fresh installs. If the Core release source or snapshot pin changes, revise
   this site candidate and rerun its checks.
2. Check the published v8.2.3 release has every linked asset. The 34 links on
   this page currently name 25 distinct assets, all present in the planned
   68-asset release inventory after H153578 substitution.
3. The `#verify` section now has 18 v8.2.3 package and snapshot SHA-256
   values rehashed from the locally staged exact-source artifacts. After the
   release is public, compare every value with the published GitHub digest.
   The snapshot card names H153578 full-v6. Do not reuse a v8.2.2 hash.
4. Keep the Docker text at the latest independently verified published image
   version. It currently says 8.2.1; update it only after the new image exists.
5. Run `python3 scripts/test_installer_snapshot.py`,
   `python3 scripts/test_release_snapshot_selection.py`, and
   `python3 scripts/verify-release-page.py`. The latter must pass against the
   public GitHub release before publishing this site change. The installer
   tests cover a signed full-v6 publisher manifest, H153578-v6-full over the
   older V5 release asset, and a digest-checked full-v6 release fallback.
6. Compare the installed download page with the candidate after deployment.

The independent DineroDPI Native 1.3.5 links stay unchanged. The Intel Ventura
Qt 6.5.3 assets retain their distinct names.
