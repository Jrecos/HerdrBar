# Changelog

## Unreleased

- Bound CLI execution on timeout and cancellation, including commands that ignore termination or leave output pipes open.
- Keep the panel clock and agent ages current when Reduce Motion is enabled.
- Preserve meaningful leading punctuation in task titles.
- Use the public account handle for copyright attribution and include the full MIT license in packaged apps.

## 0.1.1 (2026-11-06)

- Use Herdr.app's inventory so agents remain visible when core omits a remote machine; retain listed status when terminal details fail.

## 0.1.0 (2026-11-06)

- Show working, blocked, newly done, and unavailable states in the menu bar.
- Group agents by attention in a phosphor-styled panel with keyboard navigation and reduced-motion support.
- Open an agent in Herdr.app with a click or the return key.
- Read agent state through Herdr's CLIs and support launch at login.
- Render screenshots from invented fixtures with `--snapshot`.
- Include a reproducible app icon and release zip with a SHA-256 checksum.
