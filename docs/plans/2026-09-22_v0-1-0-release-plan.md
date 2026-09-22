# Display Loom v0.1.0 Release Plan

## Goal

Publish Display Loom v0.1.0 as a universal macOS app signed with Developer ID, accepted by Apple notarization, and attached to a GitHub Release with a checksum.

## Context

- `main` is clean and matches `origin/main` at `2f23cf4`.
- `MARKETING_VERSION` is `0.1.0` and `CURRENT_PROJECT_VERSION` is `1`.
- The repository has no existing tags or GitHub Releases.
- GitHub CLI authentication is available.
- The keychain currently contains only an Apple Development identity; a Developer ID Application identity and notarization credentials are still required.

## Risks

- The app uses the private `CGVirtualDisplay` API. Notarization or future macOS releases may reject or break the app even though Mac App Store distribution is not being attempted.
- Publishing an asset before stapling or from a commit other than `main` would produce an unverifiable release.
- Git tags and GitHub Releases are public remote state; publication requires explicit confirmation after the artifact passes local verification.

## Rollback / Recovery

- Before publication, remove `.release/` and rebuild; no remote state is affected.
- If publication creates an incorrect release, mark it as a draft or delete the GitHub Release and remote tag before publishing a corrected version. Never reuse `v0.1.0` after users may have downloaded it; publish a patch version instead.

## Plan

- [x] Add a reproducible release workflow that archives, Developer ID signs, notarizes, staples, verifies, packages, and checksums `Display Loom.app`; `bash -n` passes and the branch guard fails closed before credential-dependent work.
- [x] Add guarded GitHub publication tooling and v0.1.0 release notes; the script requires an explicit version confirmation, clean synchronized `main`, matching project version, artifact, checksum, and notes before creating a draft.
- [x] Document certificate and notarization setup plus release commands; `README.md` links users to signed release downloads and `docs/RELEASING.md` contains the maintainer workflow.
- [x] Run unit tests and an unsigned universal Release build; `just test` passed 56 tests with one opt-in test skipped, and `just build-release` produced version 0.1.0 build 1 for `x86_64 arm64`.
- [ ] Install a valid Developer ID Application certificate and save notarization credentials under the documented keychain profile; verify both are discoverable without exposing secrets.
- [ ] Build the v0.1.0 artifact, receive Apple notarization acceptance, staple its ticket, pass `codesign`, `stapler`, and Gatekeeper checks, and verify both architectures and checksum.
- [x] Commit and merge the reviewed release preparation into `main`; signed PR #8 merge commit `692f812` is on synchronized `main` with a clean working tree.
- [ ] After explicit confirmation, publish `v0.1.0` and its assets; verify the Git tag and public GitHub Release point to the intended commit and downloads.

## Completion Checklist

- [x] `just test` passes: 56 tests executed, one opt-in live-display test skipped, zero failures.
- [ ] The shipped app reports version `0.1.0` and build `1`; verified on the unsigned preflight build and pending verification on the notarized artifact.
- [ ] The shipped executable contains both `arm64` and `x86_64`.
- [ ] Apple notarization, stapling, code-signature validation, and Gatekeeper assessment all pass.
- [ ] The release ZIP checksum matches the published checksum file.
- [ ] GitHub Release `v0.1.0` is public and contains the signed, notarized ZIP plus checksum.
