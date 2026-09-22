# GitHub Actions Release Plan

## Goal

Provide a manually triggered GitHub Actions workflow that tests, Developer ID signs, notarizes, verifies, and publishes a Display Loom release from the current `main` commit.

## Context

- Local release scripts already package and publish signed, notarized releases.
- The repository has no GitHub Actions workflows and its default workflow token permission is read-only.
- GitHub currently provides the stable `macos-26` hosted runner; the workflow will request only `contents: write` and pin the official checkout action by commit.
- CI needs a Developer ID certificate exported as PKCS#12 plus Apple notarization credentials stored as protected GitHub environment secrets.

## Risks

- A leaked PKCS#12 file or app-specific password could authorize malicious signing or notarization. Secrets must be scoped to a protected `release` environment and imported into an ephemeral keychain.
- A failed run after pushing a tag can leave remote state that blocks retries. Publication must validate all local artifacts first and create a draft before making the release public.
- GitHub Actions cannot use the maintainer's local SSH signing key. Automated tags will be annotated but not cryptographically signed.

## Rollback / Recovery

- Failed packaging leaves no public release; delete the failed run's temporary runner and retry after fixing credentials.
- If failure occurs after tag creation, delete any draft release and remote tag before retrying the same version.
- Never reuse a version after its release may have been downloaded; publish a patch version instead.

## Plan

- [x] Update the packaging and publication scripts to support a detached CI checkout, an explicit notary keychain, deterministic Developer ID signing, and annotated CI tags while preserving signed local tags.
- [x] Add `.github/workflows/release.yml` with manual version input, strict preflight checks, pinned checkout code, least-privilege permissions, an ephemeral signing keychain, tests, notarization, verification, and guarded publication.
- [x] Document the required `release` environment secrets, PKCS#12 export, workflow invocation, tag behavior, and recovery steps in `docs/RELEASING.md`.
- [x] Validate YAML and shell syntax, run repository hooks and tests, and exercise safe failure guards without creating remote release state.
- [ ] Commit the reviewed implementation with a signed commit, push it, and merge it into `main`.

## Completion Checklist

- [x] Workflow dispatch rejects a version that differs from `project.yml` or lacks release notes.
- [x] CI imports the certificate and notarization credentials only into temporary runner files and a temporary keychain.
- [x] CI calls the same tested packaging checks used for local releases.
- [x] Publication requires the exact synchronized `main` commit and refuses existing tags or releases.
- [x] Documentation names every required secret without exposing a secret value.
