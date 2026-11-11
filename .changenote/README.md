# Change notes

Use package `display-loom` for changes that require an app release.

```sh
changenote add short-description --package display-loom --bump patch \
  --message "Describe the effect on users."
just changes
```

Use `patch` for fixes, `minor` for compatible features, and `major` for breaking changes. Commit the note with its change. Changes without release impact need no note; state the reason in the PR description. Empty notes are invalid.

The Release PR job in `.github/workflows/release.yml` consumes pending notes and updates the version and changelog on pushes to `main`. Merge its version PR to build a universal, ad-hoc-signed DMG and publish the version tag, GitHub Release, and DMG assets. No Apple credentials are required. Manual runs offer `manage-pr` and `retry-publication`. See [the release guide](../docs/RELEASING.md) for CLI installation, GitHub setup, verification, and retries.
