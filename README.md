# Display Loom

Create multiple virtual displays on macOS, with resolutions up to 8K at 60 Hz. Display Loom runs in the menu bar and lets you extend your desktop or mirror a built-in or external display.

> [!WARNING]
> This app uses the private CoreGraphics `CGVirtualDisplay` API, cannot be distributed through the Mac App Store, and may require updates after future macOS releases.

## Requirements

- macOS 14.0 or later on an Intel or Apple Silicon Mac.
- Xcode 15 or later to build from source.

## Install

Download the signed and notarized universal app from the [latest GitHub Release](https://github.com/narumiruna/display-loom/releases/latest), extract it, and move **Display Loom.app** to **Applications**.

## Build and run

With Xcode and [just](https://github.com/casey/just) installed, run from the repository root:

```sh
just run
```

This builds and launches a Debug app without requiring a signing identity. Alternatively, open `DisplayLoom.xcodeproj` in Xcode and run the `DisplayLoom` scheme.

Display Loom appears only in the menu bar, not the Dock.

## Usage

Click the display icon in the menu bar:

- Choose **Add Virtual Display** to create and connect a 1920 × 1080 display, or **Add with Resolution…** to choose a preset.
- Open a display's submenu to change its resolution, rename it, or configure mirroring.
- Choose **Disconnect** to keep its saved settings for later, **Connect** to reconnect it, or **Remove…** to delete it and its settings.

Display settings are saved. Displays left connected are restored when the app next launches.

On first launch, the app attempts to enable **Launch at Login**; you can change this in the menu. macOS may require approval in **System Settings > General > Login Items**.

## Mirroring

1. Open a connected virtual display's submenu.
2. Choose **Mirror Display**, then select an available built-in or external display as the source.
3. To return to an extended desktop, choose **Mirror Display > Do Not Mirror**.

Display Loom remembers the source and attempts to restore mirroring after the virtual display reconnects, the app relaunches, the Mac wakes, or the source display reconnects.

While mirroring, macOS controls the compatible display mode. Turn off mirroring before changing the virtual display's saved resolution.

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

The opt-in integration test creates a real virtual display, changes its resolution, and tests mirroring when a source display is available. Run it only when you are ready for changes to your display configuration:

```sh
just test-live
```

## License

[MIT](LICENSE)
