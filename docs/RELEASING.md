# Releasing Display Loom

Display Loom is distributed outside the Mac App Store as a Developer ID-signed and notarized universal macOS app. The GitHub Actions workflow in `.github/workflows/release.yml` prepares Release PRs on pushes to `main` and runs signed publication only on manual dispatch.

## Change notes and versions

[changenote](https://github.com/narumiruna/changenote) manages the `display-loom` package. Install the CLI from the same commit as the Release PR Action:

```sh
cargo install --git https://github.com/narumiruna/changenote \
  --rev f4423760122463bf03a8d161c6f0bc4173afb6e0 --locked
```

Upgrade the CLI, Action, and schema pins together. The CLI needs a stable Rust toolchain with edition 2024 support.

`Configuration/Version.xcconfig` is the release-version source for Debug and Release. Do not add `MARKETING_VERSION` overrides to `project.yml` or the generated project. A version bump does not require project regeneration.

For a change that affects app users or release artifacts, add a note and commit it with the change:

```sh
changenote add improve-display-recovery \
  --package display-loom --bump patch \
  --message "Improve display recovery after wake."
just changes
```

Use `patch` for fixes, `minor` for compatible features, and `major` for breaking changes. Changes without release impact, such as documentation-only changes and internal tooling updates, need no note. State the reason in the PR description. Do not create empty notes or run `changenote init` again.

## Prepare a version

The **Prepare Release PR** job in the **Release** workflow runs on pushes to `main`. It creates or updates one PR on `narumi/chore/changenote-release-main`. Reserve this branch for the bot. The PR updates the version file and `CHANGELOG.md`, saves `.changenote/releases.json`, and removes consumed notes. Review and merge it before publication. This job never creates tags or GitHub Releases.

To prepare the same changes locally instead, start from a clean checkout with pending notes:

```sh
just changes
just version
```

Review and commit the changed version file, changelog, saved batch, and consumed-note deletions. A run without notes does not bump the version. Do not edit the saved batch manually or run `changenote tag`; the publication script owns release tags.

`CURRENT_PROJECT_VERSION` remains a separate build number in `project.yml`; changenote does not change it. If a new build number is required, update it and run `just generate` in a separate change before preparing the release version. Keep the build number fixed during packaging and publication retries.

Merge all release preparation into `main`. The publication workflow only releases the exact current `origin/main` commit. It reads the prepared version from `Configuration/Version.xcconfig`; no version input or additional bump is required. The workflow creates the corresponding `v<version>` tag and reads that version's release notes from `CHANGELOG.md`. Existing files in `docs/releases/` remain historical records; do not add new version files there.

## Configure GitHub Actions

### Enable Release PRs

Enable **Actions > General > Allow GitHub Actions to create and approve pull requests**. Branch rules must permit the bot to push `narumi/chore/changenote-release-main`. The Action never approves or merges its PR.

The default `GITHUB_TOKEN` does not trigger PR workflows for bot-created PRs. If those workflows are required, configure a GitHub App token with contents and pull requests write permissions and pass it through the Action's `github-token` input. Verify repository permissions, branch rules, and token behavior on the first hosted run; local checks do not verify these settings. Do not merge another Release PR until the previous version and its app assets have been published.

### Export the signing identity

In **Keychain Access**, open the `login` keychain and **My Certificates**. Export **Developer ID Application: Weipo Chen (A4YQL6FFTK)** together with its private key as a password-protected PKCS#12 file.

Encode the file for a GitHub secret:

```sh
base64 -i DeveloperIDApplication.p12 | pbcopy
```

Delete the exported file after the GitHub secret is configured. Do not commit the file or its password.

### Create the protected environment

In **GitHub > Settings > Environments**, create an environment named `release`. Restrict deployment branches to `main` and add required reviewers when available.

Add these environment secrets:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_APPLICATION_P12` | Base64 output for the exported PKCS#12 file |
| `DEVELOPER_ID_APPLICATION_PASSWORD` | Password used when exporting the PKCS#12 file |
| `APPLE_ID` | Apple ID used for notarization |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password generated at `account.apple.com` |

The workflow imports these credentials into a temporary keychain and configures only Apple signing tools to use the private key. Its `always()` cleanup step deletes the deterministic certificate and keychain paths under `RUNNER_TEMP`, including when certificate import or identity validation fails before environment variables are exported.

## Run the GitHub workflow

1. Open **GitHub > Actions > Release**.
2. Choose **Run workflow** from `main`.
3. Approve the `release` environment deployment if protection rules require it.

A manual run starts only the signing and publication job. Pushes to `main` only prepare Release PRs; they do not access Apple credentials or publish the app. The jobs use separate concurrency groups, so PR updates do not block publication.

The publication job:

1. Reads the version prepared by changenote and rejects an invalid version, missing release notes, or an existing tag or release.
2. Runs unit tests without live display changes.
3. Imports the Developer ID identity into an ephemeral keychain.
4. Archives and exports a universal Release app with deterministic Developer ID signing.
5. Submits the app to Apple notarization and waits for acceptance.
6. Staples the ticket and verifies the version, build, architectures, signature, signing team, and Gatekeeper result.
7. Creates the ZIP, SHA-256 checksum, and local commit sidecar after checking that `HEAD` and the working tree have not changed during packaging.
8. Verifies that the sidecar matches `HEAD` and current `origin/main`, creates an annotated tag, uploads the ZIP and checksum to a draft GitHub Release, validates its two assets, and makes it public.

Automated tags are annotated but not cryptographically signed because GitHub Actions does not use a maintainer's local signing key. Local publication creates a signed tag.

## Local setup

1. Join the Apple Developer Program for team `A4YQL6FFTK`.
2. In **Xcode > Settings > Accounts**, select the team, open **Manage Certificates**, and create or install a **Developer ID Application** certificate.
3. Create an app-specific password for the Apple ID used for notarization.
4. Save the credentials to the login keychain. Run this directly in a terminal so the password is entered only at the secure prompt:

   ```sh
   xcrun notarytool store-credentials display-loom-notary \
     --apple-id "APPLE_ID" \
     --team-id A4YQL6FFTK
   ```

5. Verify the setup without printing secrets:

   ```sh
   security find-identity -v -p codesigning | grep "Developer ID Application"
   xcrun notarytool history --keychain-profile display-loom-notary
   ```

To use another keychain profile or team, set `NOTARY_PROFILE`, `NOTARY_KEYCHAIN`, or `DEVELOPMENT_TEAM` when running the packaging command.

## Run a local release

After preparing the version on a clean, synchronized `main`, run:

```sh
just test
just package-release 0.2.0
```

`package-release` creates these files after all signing, notarization, and Gatekeeper checks pass:

- `.release/Display-Loom-<version>.zip`
- `.release/Display-Loom-<version>.zip.sha256`
- `.release/Display-Loom-<version>.zip.commit`

The `.commit` sidecar records the full source `HEAD` captured before packaging. Packaging rechecks `HEAD` and the clean working tree before writing the sidecar. If either changed, packaging fails without a valid sidecar. Do not modify these files; rebuild them instead.

Publication requires the recorded commit to match `HEAD`, requires `HEAD` to match current `origin/main`, and verifies the ZIP checksum before creating a tag or writing to GitHub. A missing or stale sidecar blocks publication even when the version and checksum still match. Repackage from the intended commit; do not copy or edit a sidecar to reuse an old ZIP. Only the ZIP and checksum are public release assets.

Review the artifact and release notes before explicitly confirming publication:

```sh
changenote release-notes --package display-loom --version 0.2.0
CONFIRM_PUBLISH=v0.2.0 just publish-release 0.2.0
```

The publication script extracts this changelog entry into `.release/release-notes.md` before it creates a tag. A missing, duplicate, or empty version entry stops publication. Signing, notarization, Gatekeeper checks, and public release publication still require the existing macOS workflow or local credentials; Release PR automation does not verify them.

## Performance change validation

The display performance changes have deterministic checks in `just test-performance`. The backend and store check functions also have XCTest wrappers. The bridge fake checks run as a separate executable. These checks use production code with injected operations; they do not change the host's display configuration.

Available evidence:

- With Xcode 26.6 at `/Applications/Xcode.app`, `just build`, `just test`, and `just build-release` passed for the review-finding implementation. XCTest reported 84 tests, with the live test skipped and zero failures. The unsigned Release build includes arm64 and x86_64. These results do not verify signing or notarization.
- `just lint` passed strict Swift Format and SwiftLint checks with zero SwiftLint violations across 29 files.
- `just test-performance` passed 15 backend/worker checks and 13 store/service groups, plus nine fake initializer ownership cases and three mirror mode guards. These checks do not change live displays.
- `just test-release` passed eight changenote integration checks and 13 mocked release safety tests, including shell syntax checks. The combined suite preserves the separate workflow jobs and validates commit provenance. No real release operations ran.
- With four unchanged profiles, 100 notifications produce one source scan, zero restore calls, and zero `objectWillChange` notifications. The baseline at `a7d259d` produced 100 scans, 400 restore attempts, and 1,000 publisher notifications. Publisher counts are not measured SwiftUI renders.
- Gated operations verify registration yielding, a monotonic two-second registration deadline, cancellation and late-handle cleanup, serialized invalidation, and worker-side mirror checks before mode changes.
- Store/service checks verify main-actor availability, merged updates during suspended work, failure feedback suppression, in-flight wake and topology recovery, stale-result rejection, replacement ordering, teardown, saved intent, and resolution error handling. Mode checks compare saved and applied resolutions, including an older successful write followed by a newer failed write.
- Earlier Command Line Tools checks compiled production Swift and Objective-C for the native arm64 macOS 14 target with warnings treated as errors. Intel x86_64 Swift type-checking and Objective-C syntax checks for the same deployment target also passed. Those checks were not a full application build or a compatibility test on macOS 14 hardware. Public SDK headers do not require these configuration writes to run on the main thread; private API threading remains undocumented. Configuration callbacks must only schedule recovery, not perform configuration writes inline.

The following external checks remain unverified:

1. **Live display behavior and latency**
   - Responsible role: maintainer who can safely change the host's display configuration.
   - Prerequisite: a successful full build, a recoverable test setup, and explicit approval for display changes.
   - Action: after explicit approval, run `just test-live`; check multiple displays, a virtual display used as a mirror primary, rapid source changes, disconnect/reconnect during pending work, source reconnection, and sleep/wake. Capture a main-thread trace during mirror changes. Use macOS 14 and a current supported macOS version where available, and record missing OS/device coverage.
   - Expected result: saved mirror intent and recovery remain correct, stale operations do not change the final selection, and mirror transactions do not occupy the main thread.
   - Unverified behavior: private API compatibility, real display recovery, menu responsiveness, and system latency have not been established by test doubles.
   - Release restriction: observed safety or recovery failures block release. Do not claim measured latency gains or complete live-display validation without this evidence.

2. **Real release validation**
   - Responsible role: release operator with configured Developer ID and notarization credentials.
   - Prerequisite: a separately approved release and successful build and display-safe checks for the release revision.
   - Action: run the signing, notarization, Gatekeeper, and publication steps through the documented workflow or local release process.
   - Expected result: a signed and notarized universal app, a tag at its recorded source commit, and a public release with exactly the ZIP and checksum assets.
   - Release restriction: real signing, notarization, and workflow execution were not tested in this work. Unsigned builds and mocked release checks do not establish release readiness.

## Release tooling checks

With the pinned changenote CLI, XcodeGen, and uv installed, run:

```sh
just test-release
```

The recipe runs both release test suites:

- `scripts/test-changenote.py` verifies version updates, note consumption, changelog extraction, generated-project stability, workflow event routing, and publication guards with temporary files and mocked Git and GitHub commands.
- `scripts/tests/test_release.py` runs copies of the actual release scripts and the workflow certificate import and cleanup shell blocks. All external commands in this suite are mocked. It covers matching and stale commits, missing or empty provenance, checksum mismatch, source changes during packaging, and cleanup after import or identity validation failure. Rejected publication checks verify that no tag, push, or GitHub Release write is attempted. The suite also checks shell syntax for both scripts and every workflow shell step.

These checks do not sign apps, change keychains or displays, or create remote tags or Releases. The real GitHub workflow is not tested in this work. A release operator must validate signing, notarization, and publication with configured credentials during a separately approved release.

## Recovery

Before publication, delete `.release/` and rebuild. If a failed workflow or local publication created remote state, delete its draft GitHub Release and remote tag before retrying. If a public release may already have been downloaded, do not reuse its version; publish a patch version instead.
