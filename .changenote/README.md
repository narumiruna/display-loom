# Change notes

Use package `display-loom` for changes that require an app release.

```sh
changenote add short-description --package display-loom --bump patch \
  --message "Describe the effect on users."
just changes
```

Use `patch` for fixes, `minor` for compatible features, and `major` for breaking changes. Commit the note with its change. Changes without release impact need no note; state the reason in the PR description. Empty notes are invalid.

The Release PR job in `.github/workflows/release.yml` consumes pending notes and updates the version and changelog on pushes to `main`. Merging its same-repository PR into `main` starts the separate signing and publication job. Manual publication is also available. See [the release guide](../docs/RELEASING.md) for CLI installation, local versioning, and signed publication.
