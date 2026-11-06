# Releasing Display Loom

Display Loom is distributed outside the Mac App Store as a Developer ID-signed and notarized universal macOS app. The preferred release path is the manually triggered GitHub Actions workflow in `.github/workflows/release.yml`.

## Prepare a version

1. Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`.
2. Regenerate the Xcode project with `just generate`.
3. Add `docs/releases/v<version>.md` with highlights, requirements, installation steps, and relevant warnings.
4. Merge the changes into `main`. The workflow only releases the exact current `origin/main` commit.

Version input uses `MAJOR.MINOR.PATCH` without the `v` prefix. The workflow creates the corresponding `v<version>` tag.

## Configure GitHub Actions

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

The workflow imports these credentials into a temporary keychain, configures only Apple signing tools to use the private key, and deletes temporary credential files at the end of the job.

## Run the GitHub workflow

1. Open **GitHub > Actions > Release**.
2. Choose **Run workflow** from `main`.
3. Enter the version without `v`, such as `0.2.0`.
4. Approve the `release` environment deployment if protection rules require it.

The workflow:

1. Rejects a non-`main` dispatch, mismatched project version, missing release notes, or existing tag or release.
2. Runs unit tests without live display changes.
3. Imports the Developer ID identity into an ephemeral keychain.
4. Archives and exports a universal Release app with deterministic Developer ID signing.
5. Submits the app to Apple notarization and waits for acceptance.
6. Staples the ticket and verifies the version, build, architectures, signature, signing team, and Gatekeeper result.
7. Creates the ZIP and SHA-256 checksum.
8. Creates an annotated tag, uploads a draft GitHub Release, validates its assets, and makes it public.

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

`package-release` creates `.release/Display-Loom-<version>.zip` and its SHA-256 checksum after all signing, notarization, and Gatekeeper checks pass. Do not modify the ZIP; rebuild it instead.

Review the artifact and release notes before explicitly confirming publication:

```sh
CONFIRM_PUBLISH=v0.2.0 just publish-release 0.2.0
```

## Performance change validation

The display performance changes have deterministic checks in `just test-performance`. The same check functions have XCTest wrappers. These checks use the production store, backend, mirroring service, and Objective-C bridge with injected operations; they do not change the host's display configuration.

Available evidence:

- `just test-performance` passes 27 shared check functions: 14 backend/worker checks and 13 store/service groups. Three consecutive complete runs passed. Applicable pre-commit hooks, test-source syntax parsing, and Xcode project structure checks also passed.
- With four unchanged profiles, 100 notifications produce one source scan, zero restore calls, and zero `objectWillChange` notifications. The baseline at `a7d259d` produced 100 scans, 400 restore attempts, and 1,000 publisher notifications. Publisher counts are not measured SwiftUI renders.
- Gated operations verify registration yielding, a monotonic two-second registration deadline, cancellation and late-handle cleanup, serialized invalidation, and worker-side mirror checks before mode changes.
- Store/service checks verify main-actor availability, merged updates during suspended work, failure feedback suppression, in-flight wake and topology recovery, stale-result rejection, replacement ordering, teardown, saved intent, and resolution error handling. Mode checks compare saved and applied resolutions, including an older successful write followed by a newer failed write.
- The current Command Line Tools host compiles production Swift and Objective-C for the native arm64 macOS 14 target with warnings treated as errors. Intel x86_64 Swift type-checking and Objective-C syntax checks for the same deployment target also pass. This is not a full application build or a compatibility test on macOS 14 hardware. Public SDK headers do not require these configuration writes to run on the main thread; private API threading remains undocumented. Configuration callbacks must only schedule recovery, not perform configuration writes inline.

The following external checks remain unverified:

1. **Full application and XCTest validation**
   - Responsible role: maintainer with a macOS build host and full Xcode.
   - Prerequisite: the developer directory expected by `justfile`, or an explicit `DEVELOPER_DIR` override.
   - Action: run `just build`, `just test`, and `just build-release` on the implementation revision. Run the repository pre-commit hooks and attach results. The live test must remain skipped in the default suite.
   - Expected result: Debug and Release builds succeed and the unit suite passes. CLI checks alone do not verify application packaging or the full XCTest suite.
   - Release restriction: do not release the implementation until these checks pass. On the current host, all three Xcode commands fail because `/Applications/Xcode.app/Contents/Developer` is absent.

2. **Live display behavior and latency**
   - Responsible role: maintainer who can safely change the host's display configuration.
   - Prerequisite: a successful full build, a recoverable test setup, and explicit approval for display changes.
   - Action: run `just test-live`; check multiple displays, rapid source changes, disconnect/reconnect during pending work, source reconnection, and sleep/wake. Capture a main-thread trace during mirror changes. Use macOS 14 and a current supported macOS version where available, and record missing OS/device coverage.
   - Expected result: saved mirror intent and recovery remain correct, stale operations do not change the final selection, and mirror transactions do not occupy the main thread.
   - Unverified behavior: private API compatibility, real display recovery, menu responsiveness, and system latency have not been established by test doubles.
   - Release restriction: observed safety or recovery failures block release. Do not claim measured latency gains or complete live-display validation without this evidence.

## Recovery

Before publication, delete `.release/` and rebuild. If a failed workflow or local publication created remote state, delete its draft GitHub Release and remote tag before retrying. If a public release may already have been downloaded, do not reuse its version; publish a patch version instead.
