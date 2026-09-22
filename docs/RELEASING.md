# Releasing Display Loom

Display Loom is distributed outside the Mac App Store as a Developer ID-signed and notarized universal macOS app.

## One-time setup

1. Join the Apple Developer Program for team `A4YQL6FFTK`.
2. In **Xcode > Settings > Accounts**, select the team, open **Manage Certificates**, and create or install a **Developer ID Application** certificate.
3. Create an app-specific password for the Apple ID used for notarization.
4. Save the credentials to the login keychain. Run this command directly in a terminal so the password is entered only at the secure prompt:

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

To use another keychain profile or team, set `NOTARY_PROFILE` or `DEVELOPMENT_TEAM` when running the packaging command.

## Prepare a release

1. Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`, regenerate the Xcode project with `just generate`, and add `docs/releases/v<version>.md`.
2. Merge those changes into `main` and ensure local `main` is clean and matches `origin/main`.
3. Run the checks and create the signed artifact:

   ```sh
   just test
   just package-release 0.1.0
   ```

`package-release` performs these operations:

1. Archives and exports a universal Release app with Developer ID signing.
2. Verifies the app version, build number, architectures, signature, and signing team.
3. Submits the app to Apple notarization and waits for acceptance.
4. Staples and validates the notarization ticket, then runs Gatekeeper assessment.
5. Creates `.release/Display-Loom-<version>.zip` and its SHA-256 checksum.

Do not modify the ZIP after this command succeeds. Rebuild it instead.

## Publish

Review the release notes and artifact before explicitly confirming publication:

```sh
CONFIRM_PUBLISH=v0.1.0 just publish-release 0.1.0
```

The publication command verifies the checksum and repository state, creates a draft GitHub Release and tag from the exact `main` commit, validates the tag and uploaded asset count, and then makes the release public.

## Recovery

Before publication, delete `.release/` and rerun packaging. If a draft is incorrect, delete its GitHub Release and tag before retrying. If a public release may already have been downloaded, do not reuse its version; publish a patch release instead.
