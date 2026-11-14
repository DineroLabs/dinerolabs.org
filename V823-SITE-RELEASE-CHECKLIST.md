# v8.2.3 site candidate — local hold

This branch prepares the download page for the planned v8.2.3 release. A draft
PR can run checks early; do not merge or deploy it until the release is public
and the checks below pass.

1. Confirm the final full-v6 snapshot base. This candidate links H152700. If
   release qualification selects H153051, update all H152700 links and copy.
2. Check the published v8.2.3 release has every linked asset. The 34 links on
   this page currently name 25 distinct assets, all present in the planned
   63-asset matrix after H152700 substitution.
3. In the `#verify` section of `index.html`, replace every remaining v8.2.2
   filename and SHA-256 digest with the *published* v8.2.3 asset's filename
   and GitHub digest. Change the snapshot card to the final full-v6 base.
   Never reuse a v8.2.2 hash for a v8.2.3 filename.
4. Keep the Docker text at the latest independently verified published image
   version. It currently says 8.2.1; update it only after the new image exists.
5. Run `python3 scripts/test_installer_snapshot.py`,
   `python3 scripts/test_release_snapshot_selection.py`, and
   `python3 scripts/verify-release-page.py`. The latter must pass against the
   public GitHub release before publishing this site change. The installer
   tests cover a signed full-v6 publisher manifest, H152700-v6-full over the
   older V5 release asset, and a digest-checked full-v6 release fallback.
6. Compare the installed download page with the candidate after deployment.

The independent DineroDPI Native 1.3.5 links stay unchanged. The Intel Ventura
Qt 6.5.3 assets retain their distinct names.
