# HerdrBar

HerdrBar by [Jrecos](https://github.com/Jrecos) is a free, open-source macOS menu bar app for monitoring coding agents in [Herdr.app](https://herdr.dev). See which agents are blocked, working, or newly finished, then open an agent in Herdr with a click.

HerdrBar is an independent community companion, not an official Herdr plugin. It runs as a separate app and uses Herdr's command-line tools. It does not install a mod.

[Download HerdrBar](https://github.com/Jrecos/HerdrBar/releases/latest) · [Installation](#install) · [Requirements](#requirements) · [Agent reference](llms.txt)

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)
![MIT license](https://img.shields.io/badge/license-MIT-green)

![HerdrBar panel with blocked, done, running, and idle agents from an invented fixture](docs/screenshots/mixed.png)

This illustrative fixture shows sample ages on done and idle rows. The live app shows "age unavailable" for those rows.

## What it shows

The menu bar item shows a braille spinner while agents work, `!N` with a pulsing alert glyph when any agent is blocked, and `✓N` when agents finished while you weren't looking. When Herdr isn't running the glyph dims.

The panel groups agents by what they need from you, in this order: blocked, done, running, idle, and unknown. Each row shows the space, the machine for remote agents, its current task, and the state age when supported by core details. Idle and done ages are unavailable because core cannot establish when Herdr's displayed attention changed. When details are unavailable, the row keeps the status from Herdr and explicitly shows that the task and age are unavailable. Rows slide in when the panel opens and flash when an agent changes state. The panel respects the system "Reduce motion" setting.

![HerdrBar panel when no agents are available](docs/screenshots/empty.png)

## Requirements

- macOS 14 or later.
- The prebuilt v0.1.1 download targets Apple silicon.
- [Herdr.app](https://herdr.dev) with `herdr-app` installed. `hc` (also shipped as `herdr-core`) supplies task titles and state ages when available.

## Install

1. Download `HerdrBar-0.1.1.zip` from [Releases](https://github.com/Jrecos/HerdrBar/releases).
2. Unzip the archive.
3. Move `HerdrBar.app` to `/Applications`.
4. Open it. The build is ad-hoc signed and not notarized, so macOS blocks the first launch:
   - **macOS 15 and later:** open **System Settings › Privacy & Security** and click **Open Anyway** next to HerdrBar.
   - **macOS 14:** right-click the app and choose **Open**.

Or remove the quarantine attribute, then open the app:

```sh
xattr -dr com.apple.quarantine /Applications/HerdrBar.app
open /Applications/HerdrBar.app
```

## Build from source

Use macOS 14 or later with a Swift 6 toolchain.

```sh
git clone https://github.com/Jrecos/HerdrBar.git
cd HerdrBar
./Scripts/package_app.sh release
open HerdrBar.app
```

The script signs the app ad hoc. Set `APP_IDENTITY` to your Developer ID Application identity to sign with your certificate.

Right-click the menu bar item for "Launch at Login", "Open Herdr" and "Quit HerdrBar".

## Keys

With the panel open:

| Key | Action |
| --- | --- |
| ↑ / ↓ | Move the selection |
| ↵ | Open the selected agent in Herdr |
| ⌫ / forward delete | Arm closing the selected session, then press again to confirm |
| esc | Cancel an armed close, or close the panel |

Clicking outside the panel also closes it.

Hover over or select a row to reveal its ✕ button. Click it once to show `[kill?]`, then again to close the session. Closing ends the terminal. If it is the space's last terminal, closing also removes the space. Moving the selection, hovering another row, or pressing esc cancels confirmation. Return still opens the agent.

## How it works

This section describes the current source. The v0.1.1 download predates the subprocess timeout fixes listed under [Unreleased](CHANGELOG.md#unreleased).

HerdrBar runs Herdr's own CLIs. Listing and detail requests query Herdr, though core may persist registry state while serving them. Focusing an agent changes Herdr's selection. A confirmed close ends the selected terminal and removes its pane, or its space when it has no other terminals.

| Command | Purpose |
| --- | --- |
| `herdr-app ls` | Authoritative space, terminal and attention inventory |
| `hc get --json <address>` | Enriches a terminal with its title and status time when available |
| `hc --version`, `herdr-app --version` | Confirms a candidate binary before each refresh; `hc` is optional for detail enrichment |
| `herdr-app do agent.focus '{"terminal":"<address>"}'` | Open the agent you clicked (after activating Herdr.app) |
| `herdr-app do pane.close '{"pane":"<pane>"}'` | Close a confirmed session when its space has other terminals |
| `herdr-app do space.close '{"id":"<space>","confirmed":true}'` | Close a confirmed session when it is the space's last terminal |

It refreshes every 5 seconds, or every 2 seconds while the panel is open. Each call runs off the main thread with a 3 second timeout. Timeout and cancellation send `SIGKILL` to the command's process group, close its output pipes, and return without waiting for process exit.

An agent is a terminal whose program reports a status. HerdrBar shows the terminals Herdr.app lists, including child terminals when listed. Attention comes from Herdr.app's listing, including its seen/unseen decision; an `error` status shows as blocked. If a detail request fails, the terminal remains visible with its listed attention and unavailable task and age. Unrecognized statuses appear as unknown.

GUI apps don't inherit your shell `PATH`, so HerdrBar looks for the CLIs in this order: the paths in its own settings, `PATH`, then `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin`. A candidate for `hc` must answer `--version` with a line starting `hc `. To point HerdrBar at a CLI somewhere else:

```sh
defaults write io.github.jrecos.herdrbar hcPath /path/to/hc
defaults write io.github.jrecos.herdrbar herdrAppPath /path/to/herdr-app
```

## Privacy

HerdrBar itself makes no network calls and collects no telemetry. It reads the two optional CLI path settings above from its defaults domain. "Launch at Login" registers a login item with macOS. These statements cover HerdrBar, not Herdr.app or the command-line tools it invokes.

The README screenshots use invented names, tasks, machines, and IDs from `docs/fixtures`. They are rendered with `--snapshot`, not captured from live sessions.

The live panel shows your space names, machine names, and task titles. Running `--snapshot` without `--fixture` exports that live information to an image. Use an invented fixture for screenshots you plan to share.

The app credits the public GitHub handle `Jrecos` and includes the full MIT license in `HerdrBar.app/Contents/Resources/LICENSE`.

## Development

```sh
swift build
swift test
./Scripts/compile_and_run.sh      # build, package, relaunch
./Scripts/compile_and_run.sh --test
```

`HerdrBarCore` holds the models, CLI client, JSON parsing, attention rules, and formatting without AppKit. `HerdrBar` owns the status item, panel, animations, and right-click menu. Core tests use invented JSON fixtures in the CLI output format.

To regenerate the README screenshots from fixtures:

```sh
HerdrBar.app/Contents/MacOS/HerdrBar --snapshot docs/screenshots/mixed.png --fixture docs/fixtures/mixed.json
HerdrBar.app/Contents/MacOS/HerdrBar --snapshot docs/screenshots/empty.png --fixture docs/fixtures/empty.json
```

To rebuild the icon and create the release archive:

```sh
./Scripts/build_icon.sh
./Scripts/release_zip.sh
```

`version.env` supplies the app and archive version. The archive script builds release mode and writes `dist/HerdrBar-<version>.zip` and its `.zip.sha256` checksum.

The panel uses "JetBrainsMono Nerd Font" (or "JetBrainsMonoNL Nerd Font") when it is installed, otherwise the system monospace font.

See [AGENTS.md](AGENTS.md) for the layout and conventions.

## Questions

### Is HerdrBar an in-app Herdr mod?

No. HerdrBar is a separate macOS app. Herdr's [community gallery](https://herdr.dev/gallery/) accepts in-app mods and layouts with a different package format. Installing HerdrBar does not add an entry to that gallery or imply Herdr endorsement.

### Does HerdrBar work with Herdr TUI?

HerdrBar uses Herdr.app's `herdr-app` CLI. Herdr TUI is a separate program with a separate server, so its agents do not appear in Herdr.app. See [Herdr's compatibility answers](https://herdr.dev/#faq).

### Is HerdrBar free?

Yes. The source code is available under the [MIT license](LICENSE). Release builds are ad-hoc signed and not notarized. Read the [first-launch instructions](#install) before downloading.

## For agents and search

[llms.txt](llms.txt) links to the product documentation, installation requirements, releases, and source. It is a reference for agents, not a Google indexing requirement.

Google says [AI Overviews and AI Mode use the same SEO fundamentals as Search](https://developers.google.com/search/docs/appearance/ai-features). No special AI file is required. Search indexing, citations, and rankings are not guaranteed.

## License

MIT. See [LICENSE](LICENSE).

Inspired by [CodexBar](https://github.com/steipete/CodexBar) by Peter Steinberger.
