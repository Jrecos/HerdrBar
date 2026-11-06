# Changelog

## 0.1.0 (unreleased)

- Menu bar item with a braille spinner while agents work, `!N` with a pulsing alert glyph when any agent is blocked, `✓N` for agents done since you last looked, and a dimmed glyph when Herdr is unavailable.
- Phosphor-styled panel grouped by attention (blocked, done, running, idle) with hover, keyboard navigation, staggered entry, and a flash on state change. "Reduce motion" turns the animations off.
- Click or press return on a row to focus that agent in Herdr.app.
- Reads Herdr through `hc ls --json`, `hc get --json`, and `herdr-app ls`; finds the CLIs without the shell `PATH`; 3 second timeout per call.
- `--snapshot <png> [--fixture <json>]` renders the panel headlessly.
- Right-click menu with "Launch at Login" (`SMAppService`), "Open Herdr" and "Quit HerdrBar".
- `Scripts/package_app.sh` builds an ad-hoc signed `HerdrBar.app`; `Scripts/compile_and_run.sh` is the dev loop.
