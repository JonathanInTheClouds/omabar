# Changelog

## 0.1.0 (2026-10-04)

First release.

- 17 built-in Touch Bar layouts: Duotone, Duotone Weather, Quiet, Keycaps, Workspaces, Capture, Windows, Desk Clock, Studio, Meeting, Dev, Themes, Quick Settings, Clipboard, Presenter, Browser, Numpad.
- Bar panel with a to-scale preview (main and Fn rows) sized to the real Touch Bar, and one-click Activate.
- Follow the focused app, with per-app rules, a manual pick for unmatched apps, and empty-desktop handling.
- Weather button (Open-Meteo), refreshed every 15 minutes.
- Colours: Omabar's own palette, or match the Omarchy theme, kept readable on black and updated on theme change.
- Passwordless, blink-free switching through a small root helper with a polkit rule. Icons install automatically.
- `install.sh` does the Intel T2 setup: tiny-dfr, keyboard-to-display mode, and a resume fix for the Touch Bar dropping off after sleep.
- `omabar doctor`, `omabar migrate` (from the jonathan.touchbar-layouts prototype), sandboxed `tests/smoke.sh`, and AGENTS.md for AI-assisted customisation.
