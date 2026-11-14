# Changelog

## 0.2.0

### Minor Changes

- Add a management window and Dock access while keeping menu bar controls.
  
  Keep all pending errors from overlapping display actions. Show automatic error and login approval notices only when the app is active.
  
  Restore the saved resolution selection after a cancelled or rejected change.

- Add per-display 60 Hz (default) and 30 Hz (low refresh rate) choices to the management window and menu bar. Save the choice across reconnects and app relaunches. Older saved displays keep 60 Hz.
  
  Keep refresh-rate controls unavailable while mirroring. Select an exact reported refresh rate instead of silently using a mode with an unknown rate.

### Patch Changes

- Fix connection failures when macOS places a virtual display in a mirror set during connection. Keep mirroring active and let macOS select its compatible resolution.

## 0.1.3

### Patch Changes

- Fix release checks on macOS so automated DMG packaging can complete.

## 0.1.2

### Patch Changes

- Distribute universal DMG packages through GitHub Releases without Apple signing credentials. Version PRs, tags, and release notes are managed by changenote.

## 0.1.1

### Patch Changes

- Fix virtual display initialization and prevent resolution changes for mirror primaries. Bind release artifacts to their source commit and clean temporary credentials after failed imports.

## 0.1.0

Display Loom's first public release.

## Highlights

- Create and manage multiple persistent virtual displays from the macOS menu bar.
- Choose native 16:9 and 16:10 resolutions up to 8K at 60 Hz.
- Extend the desktop or mirror a built-in or external display.
- Restore connected displays and mirroring preferences after launch, wake, or source reconnection.
- Optionally launch the app at login.
- Run natively on Apple Silicon and Intel Macs.

## Requirements

- macOS 14.0 or later.
- An Apple Silicon or Intel Mac.

## Install

1. Download `Display-Loom-0.1.0.zip` and its checksum file.
2. Optionally verify the download with `shasum -a 256 -c Display-Loom-0.1.0.zip.sha256`.
3. Extract the ZIP and move **Display Loom.app** to **Applications**.
4. Open Display Loom. Its display icon appears in the menu bar rather than the Dock.

> [!WARNING]
> Display Loom uses the private CoreGraphics `CGVirtualDisplay` API. It cannot be distributed through the Mac App Store and may require updates after future macOS releases.
