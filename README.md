<div align="center">

# EdgeCompanion

An all-in-one macOS app for the Corsair XENEON EDGE.

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)](#requirements)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-555555)](#requirements)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://www.swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**English** · [한국어](README.ko.md)

<img src="docs/dashboard.png" alt="EdgeCompanion dashboard on a XENEON EDGE: terminal, clock, temperatures, memory, launcher, CPU, Claude Code and Codex usage, audio output and system info" width="100%">

</div>

Corsair's iCUE doesn't support the XENEON EDGE on macOS. Touches land on the wrong display and
the panel settings can't be changed. EdgeCompanion handles both, and can turn the Edge into a
dashboard. It is an unofficial project and not affiliated with Corsair.

## Features

- Touch input mapped to the Edge. Supports tap, double tap, scrolling with momentum, hold then
  drag, and long press for right-click. Touching the dashboard doesn't move the mouse cursor.
- Dashboard widgets: clock, CPU per core, GPU, memory, network and disk, temperatures, power and
  Bluetooth device batteries, Claude Code and Codex usage limits, volume and output device,
  timer (±1 minute), app launcher, system info, and an optional terminal on one side.
- Apple Music on the clock widget's second page: artwork, track, progress (tap to seek) and
  playback buttons. It comes to the front while music plays and steps back once playback stops.
- A web page widget showing any address you set, with logins kept between launches.
- Photo and video widgets (as many as you like): a photo, GIF or video filling the card on an
  endless loop, muted and paused while the Edge is off.
- A sleep widget: keeps the Mac and its displays awake for 1, 4, 8 or 24 hours (like
  `caffeinate -d`), and swiping up on it then tapping puts the Mac to sleep.
- Widgets in 1×1, 2×1, 1×2 and 2×2 sizes, several dashboard pages, widgets with their own pages,
  and a layout editor in Settings.
- Panel white balance over DDC/CI. The values are stored in the panel, so they stay after the
  app quits. The D65 preset corrects the bluish factory white.
- In dashboard mode the mouse pointer can't enter the Edge (hold <kbd>Option</kbd> to let it in),
  the Dock stays off it, and other windows that end up there are moved to the main display.
- The panel is recognized by its serial number; settings are applied again after reconnecting
  or waking from sleep.
- Uses about 1–2% of one CPU core while the dashboard is visible, and stops sampling while the
  Edge is asleep or unplugged.
- English and Korean UI.

## In use

<p align="center">
  <img src="docs/setup.jpg" alt="A XENEON EDGE below a monitor, running the EdgeCompanion dashboard" width="85%">
</p>

## Requirements

- Apple Silicon Mac with macOS 14 or later (tested on macOS 26, MacBook Air M5 15-inch)
- XENEON EDGE connected over USB-C (DisplayPort Alt Mode) for DDC/CI
- Xcode or the Command Line Tools (Swift 6)

## Install

There are no prebuilt releases yet. Build it from source:

```sh
git clone https://github.com/Seol-JY/xeneon-edge-companion.git
cd xeneon-edge-companion
scripts/make-cert.sh            # once: creates a local self-signed code-signing certificate
scripts/build-app.sh --install  # builds, copies to ~/Applications and launches
```

macOS ties privacy permissions to the code signature. With the local certificate they survive
rebuilds; with ad-hoc signing they have to be granted again after every build. To use another
certificate, set `SIGN_ID` or write its name to `.signing-identity`. Set `BUNDLE_ID` to build
under your own bundle identifier.

Permissions requested on first launch:

| Permission | Used for |
|---|---|
| Input Monitoring | Reading the touch controller |
| Accessibility | Touching other apps' windows, the pointer guard, moving windows |
| Automation (Music) | Artwork, position and playback buttons for Apple Music. Asked the first time music plays; without it the track still shows |

## Usage

The menu bar menu shows the Edge and touch status, switches between dashboard mode and regular
display mode, applies color presets and opens Settings.

- Moving a finger scrolls. Holding briefly and then moving drags. Holding still right-clicks.
- Swipe sideways on the dashboard to change pages. Widgets with dots at the bottom have their own
  pages; swipe on the widget or tap a dot.
- Settings → Dashboard → Widget layout: drag tiles to reorder them, click a tile to change its
  size, move it to another page or remove it. "Empty space" tiles can be used for gaps.
- Web page widget: set the address and zoom in Settings → Dashboard → Web page widget. "Open"
  shows the same page in a window on the main display, for signing in with a keyboard; the widget
  shares its cookies. Links that leave the page show a home button on the widget.
- Photo and video widgets: click the tile in the widget layout, then "Choose file…". The file is
  copied into `~/Library/Application Support/EdgeCompanion/Media`, so the original can be moved or
  deleted. Fill crops to the card; Fit shows the whole picture.
- If tmux is installed, the terminal runs in its own tmux server and keeps running when the app
  restarts. Attach from another terminal with `tmux -L edge attach -t edge`.

### Claude Code and Codex usage

The usage widget shows the 5-hour and weekly limits of both tools. It does not read any login
tokens.

- Claude Code 2.1.80 and later pass rate-limit data to the configured status line command.
  Settings → Dashboard → Usage limits → Connect registers EdgeCompanion as that command. It backs
  up `~/.claude/settings.json` first and won't replace an existing status line. Only the
  percentages and reset times are stored. Claude Code's status line then shows `5h 12% · 7d 30%`.
- For Codex, the app asks the Codex CLI's `app-server` (`account/rateLimits/read`); the CLI makes
  the authenticated request itself. Without the CLI, the last session log is used.

Anthropic's terms don't allow using a Claude subscription's OAuth token in other apps, which is
why the status line is used instead.

### Color

Settings → Color writes the panel's RGB gains (VCP 0x16, 0x18 and 0x1A, under the User 1 preset
set with 0x14). No other VCP codes are written, including input select, power and factory reset,
which could turn off a panel that has no buttons. Brightness is left to tools such as
MonitorControl.

## Privacy and security

- Network requests are made only by features you turn on: the web page widget loads its page,
  and for Apple Music tracks without artwork the track's title and artist are sent to Apple's
  iTunes Search API to find the cover. The Codex CLI makes its own request when the usage widget
  is shown.
- Apple Music is read through its own notifications and AppleScript; macOS asks once for
  Automation permission.
- Connecting Claude Code rewrites `~/.claude/settings.json` after saving a timestamped backup next
  to it. Disconnect removes the entry.
- Without the Codex CLI, the newest Codex session log is read for its `rate_limits` record only.
- Settings are stored in user defaults and logs in `~/Library/Logs/EdgeCompanion`.
- The app isn't sandboxed, because SMC sensors, DDC and the touch controller need direct hardware
  access.
- Some features use private macOS APIs (DDC through `IOAVService`, hiding the cursor from the
  background). They are optional, and the app keeps working if they fail.

## FAQ

<details>
<summary><b>Does multi-touch work?</b></summary>

No. The panel firmware enables multi-touch only for Windows and reports a single contact on
macOS, so all gestures use one finger.
</details>

<details>
<summary><b>Touch status says another app is using the controller.</b></summary>

Only one app can open the touch controller at a time. Quit other XENEON EDGE touch drivers.
</details>

<details>
<summary><b>Where are the logs?</b></summary>

In `~/Library/Logs/EdgeCompanion/EdgeCompanion.log`, and in Settings → Diagnostics.
</details>

## Development

```
Sources/EdgeCore        Logic with unit tests: touch reports, gestures, mapping, DDC packets, pointer and grid geometry
Sources/EdgeCompanion   The app: display, color, touch, pointer guard, dashboard, telemetry, usage, settings
Tests/EdgeCoreTests     Unit tests (swift-testing)
scripts/                Build, signing and test scripts
```

```sh
scripts/test.sh                                   # unit tests
dist/EdgeCompanion.app/Contents/MacOS/EdgeCompanion --render-widgets /tmp/w timer volume   # render widgets to PNG
```

## Acknowledgements

Parts of the code and approach come from [exelban/stats](https://github.com/exelban/stats),
[vladkens/macmon](https://github.com/vladkens/macmon),
[MonitorControl](https://github.com/MonitorControl/MonitorControl),
[DockAnchor](https://github.com/bwya77/DockAnchor) and
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm). The touch protocol details come from the
community XENEON EDGE driver projects. The terminal font is
[JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) with
[Nerd Fonts](https://github.com/ryanoasis/nerd-fonts) icons. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Feedback

Bug reports and suggestions are welcome in [Issues](../../issues). Please include your macOS
version and the log from Settings → Diagnostics. If you find the project useful, a star helps
other XENEON EDGE owners find it.

## Disclaimer

This software is provided as is, without warranty of any kind. It writes settings to the display
over DDC/CI, takes over the touch controller, posts input events and uses private macOS APIs. Use
it at your own risk. The authors are not responsible for any damage, data loss, hardware problems
or other issues that result from using it.

## License

[MIT](LICENSE). CORSAIR and XENEON are trademarks of their owner and are used here only to name
the hardware.
