# Display Loom

Create multiple virtual displays on macOS, with resolutions up to 8K at 60 Hz. Use the management window or menu bar to extend your desktop or mirror a built-in or external display.

> [!WARNING]
> This app uses the private CoreGraphics `CGVirtualDisplay` API, cannot be distributed through the Mac App Store, and may require updates after future macOS releases.

## Requirements

- macOS 14.0 or later on an Intel or Apple Silicon Mac.
- Xcode 16 or later to build the checked-in project from source.

## Install

Open the [latest GitHub Release](https://github.com/narumiruna/display-loom/releases/latest) and use the steps for its file format. Existing releases can have ZIP assets instead of a DMG.

Download the package and matching `.sha256` file from the same Release. Save both files in the same directory. Replace `<version>` below with the version in the downloaded filenames. If you saved the files outside **Downloads**, change the directory path too.

Continue only if `shasum` succeeds and prints the package filename followed by `: OK`. If the check fails, stop. Do not extract the ZIP, open the DMG, or use **Open Anyway**. Download both files again from the same official Release.

1. **ZIP release:** Download `Display-Loom-<version>.zip` and `Display-Loom-<version>.zip.sha256`. In Terminal, run:

   ```sh
   cd "$HOME/Downloads"
   shasum -a 256 -c "Display-Loom-<version>.zip.sha256"
   ```

   After verification, extract the ZIP and move **Display Loom.app** to **Applications**.

2. **DMG release:** Download `Display-Loom-<version>.dmg` and `Display-Loom-<version>.dmg.sha256`. In Terminal, run:

   ```sh
   cd "$HOME/Downloads"
   shasum -a 256 -c "Display-Loom-<version>.dmg.sha256"
   ```

   After verification, open the DMG and drag **Display Loom.app** to **Applications**.

A matching checksum checks file integrity; it does not verify the publisher. New DMG builds use ad-hoc signing, not Developer ID signing or Apple notarization. Gatekeeper can block downloaded copies.

On macOS 14 and later, use the following steps only if you trust the official download and have checked its checksum:

1. Try to open **Display Loom.app** from **Applications**, then close the alert about an unverified developer or missing notarization.
2. Open **System Settings > Privacy & Security**, scroll to **Security**, and click **Open Anyway** for Display Loom.
3. Confirm **Open** and authenticate if macOS asks.

This adds an exception for this app. Do not override malware or damaged-app alerts. See [Apple's instructions](https://support.apple.com/en-us/102445#openanyway).

## Build and run

With Xcode and [just](https://github.com/casey/just) installed, run from the repository root:

```sh
just run
```

This builds and launches a Debug app without requiring a signing identity. Alternatively, open `DisplayLoom.xcodeproj` in Xcode and run the `DisplayLoom` scheme.

Display Loom opens a management window and appears in both the Dock and menu bar.

## Usage

Use the management window to control your virtual displays:

- Click **Add Virtual Display** in the toolbar to create and connect a 1920 × 1080 display. Use **Add with Resolution…** to choose a preset.
- Each display card shows its connection state, resolution, mirroring source, and controls to rename or remove it.
- Choose **Disconnect** to keep its saved settings, **Connect** to reconnect it, or **Remove…** to delete it and its settings.

The display icon in the menu bar keeps the same controls. Choose **Open Display Loom** to show the management window. If the icon is hidden by other menu bar items, click Display Loom in the Dock or open the app again.

Closing the window keeps Display Loom and its connected displays running. Use **Quit Display Loom** or press **Command-Q** to quit.

Automatic error and login approval notices wait while another app has focus. Return to Display Loom to see pending notices.

Display settings are saved. Displays left connected are restored when the app next launches.

On first launch, the app attempts to enable **Launch at Login**; you can change this in the menu. macOS may require approval in **System Settings > General > Login Items**.

## Mirroring

1. Find a connected display in the management window, or open its menu bar submenu.
2. Use **Mirror Display** to select an available built-in or external display as the source.
3. To return to an extended desktop, choose **Mirror Display > Do Not Mirror**.

Display Loom remembers the source and attempts to restore mirroring after the virtual display reconnects, the app relaunches, the Mac wakes, or the source display reconnects.

If automatic restoration fails, select the saved source again to retry. Repeated notifications for unchanged display state do not trigger repeated attempts.

While mirroring, macOS controls the compatible display mode. If a display is already in a mirror set when it connects, Display Loom keeps that state and does not apply its saved resolution. Turn off mirroring before changing the virtual display's saved resolution.

## Supported resolutions

All presets use native pixels (LoDPI, not HiDPI scaling) at 60 Hz.

| 16:9 | 16:10 |
| --- | --- |
| 1280 × 720 | 1280 × 800 |
| 1366 × 768 | 1440 × 900 |
| 1600 × 900 | 1680 × 1050 |
| 1920 × 1080 | 1920 × 1200 |
| 2560 × 1440 | 2560 × 1600 |
| 3200 × 1800 | 2880 × 1800 |
| 3840 × 2160 | 3840 × 2400 |
| 5120 × 2880 | 5120 × 3200 |
| 7680 × 4320 | 7680 × 4800 |

8K and multiple high-resolution displays can consume substantial memory and GPU resources and may reduce system stability.

## Testing

Run unit tests without creating a real virtual display:

```sh
just test
```

With macOS Command Line Tools, you can also run deterministic performance and lifecycle checks without full Xcode:

```sh
just test-performance
```

This compiles the production Swift and Objective-C code for macOS 14 and runs shared regression checks with test doubles. It does not create or reconfigure a real display. It does not replace the full app build or XCTest suite.

The opt-in integration test creates a real virtual display, changes its resolution, and tests mirroring when a source display is available. Run it only when you are ready for changes to your display configuration:

```sh
just test-live
```

### Management window checks

Before a release, check these desktop interactions manually. Unit tests check layout and display actions with test doubles, not Dock or menu bar interactions.

1. Open the app. Confirm that the management window, Dock icon, and menu bar icon appear.
2. Close the window. Confirm that the app stays running. Reopen it from the Dock and from **Open Display Loom** in the menu bar. Repeated requests must use the same window.
3. Check the empty state and display cards in English and Traditional Chinese. Check connection controls, resolution choices, and mirroring warnings. Display operations change the real desktop configuration; use a Mac prepared for those changes.
4. Cancel the rename, removal, and 8K dialogs from both interfaces. Confirm that saved settings do not change. Check error messages and picker state after a rejected operation.
5. Check that a background display error does not activate Display Loom. Return to the app and confirm that each pending notice appears once.

## Change notes and releases

Use [changenote](https://github.com/narumiruna/changenote) for release notes and version updates. See the [release guide](docs/RELEASING.md) for setup and DMG release publication, and the [changelog](CHANGELOG.md) for release history.

## Development checks

Run the release checks with [uv](https://docs.astral.sh/uv/), XcodeGen, and the pinned changenote CLI from the [release guide](docs/RELEASING.md) installed:

```sh
just test-release
```

These checks do not use signing credentials, change keychains, or publish releases.

Swift code follows the [Google Swift Style Guide](https://google.github.io/swift/).
Run the non-modifying source checks with Xcode and [SwiftLint](https://github.com/realm/SwiftLint) installed:

```sh
just lint
```

The formatter uses `.swift-format`. SwiftLint enforces the 100-column limit.
File, type, and function line-count limits are disabled because the guide does not require them;
keep tightly coupled code together. Import modules directly, and put multiple closure arguments
inside the argument list. Automated checks do not replace a style review.

## License

[MIT](LICENSE)
