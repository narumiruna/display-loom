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

## Recovery

Before publication, delete `.release/` and rebuild. If a failed workflow or local publication created remote state, delete its draft GitHub Release and remote tag before retrying. If a public release may already have been downloaded, do not reuse its version; publish a patch version instead.
