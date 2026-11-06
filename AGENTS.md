# Repository guidelines

## Layout

- `Sources/HerdrBarCore`: models (`Attention`, `Agent`, `Snapshot`), `HerdrClient` and the `hc` / `herdr-app` JSON parsing, CLI discovery, grouping, ages, `StatusBadge`, `Fixture`. Pure Swift, no AppKit. Everything except `ProcessRunner` has tests.
- `Sources/HerdrBar`: the app. `AgentStore` (refresh loop, `@Observable`), `StatusItemController` plus `BadgeImages` (menu bar), `PanelController` (NSPanel, keys, positioning), `PanelView` (SwiftUI), `SpinnerGlyph`, `Theme`, `main.swift` (snapshot mode and launch).
- `Tests/HerdrBarCoreTests`: Swift Testing suites over `Fixtures/*.json`, modelled on real CLI output.
- `docs/fixtures`: agent fixtures for `--snapshot`. `docs/screenshots`: panels rendered with `--snapshot`; the README embeds `mixed.png` and `empty.png`.
- `Scripts/package_app.sh` builds `HerdrBar.app`. `Scripts/compile_and_run.sh` is the dev loop.

## Build, test, run

- `swift build`, `swift test`.
- `./Scripts/package_app.sh [debug|release]` writes `HerdrBar.app` at the repo root, ad-hoc signed unless `APP_IDENTITY` is set.
- `./Scripts/compile_and_run.sh [--test] [--debug]` quits running copies, packages, relaunches and confirms the process started.
- `HerdrBar.app/Contents/MacOS/HerdrBar --snapshot out.png [--fixture docs/fixtures/mixed.json]` renders the panel at 2x and exits. Use it to check a UI change; screen capture is usually not available to agents.

## Conventions

- Swift 6 language mode, macOS 14, no third-party dependencies.
- `@Observable` models, `@MainActor` for anything touching AppKit. CLI calls go through `CommandRunner` so tests can fake them.
- Keep logic in `HerdrBarCore` when it does not need AppKit; add a fixture and a test with it.
- Comments only for a non-obvious why.
- Commit messages: short imperative clauses.

## Things that bite

- The status bar re-snapshots its item for every display on each change. Animate the menu bar item by swapping pre-rendered bitmaps, never by redrawing text or observing `effectiveAppearance` from inside the item (both loop at 60 to 100 percent CPU on multi-display Macs).
- `ImageRenderer` draws nothing inside a `ScrollView`; snapshot mode renders the rows without one.
- `NSHomeDirectory()` ignores `HOME` overrides. To test the unavailable state, break the socket instead (`herdr-app` fails when its socket is missing).
- Clicking a row runs `herdr-app do agent.focus`, which changes the owner's Herdr selection. Read `herdr-app status` first and restore it after a test.
