# Changelog

## 0.2.0

- **Layout editor** (Edit… in the popup): drag-and-drop button order, icon picker with live colour preview, colour swatches, widths, clocks, battery, weather and gaps, both rows. Saving a built-in keeps your own copy; Reset to built-in brings it back; New copy… duplicates.
- **Action picker:** send one of your Omarchy shortcuts (read from Hyprland), open an installed app, press a media/system/workspace key, or run any command. Omabar assigns a free spare key and writes the bind.
- **Try on Touch Bar:** puts the draft on the real bar for 20 seconds, then rolls back. Follow mode and weather pause meanwhile.
- **Rules editor:** add rules from running apps, reorder, pick layouts, set the default and the shortcut.
- **Shortcut:** SUPER + ALT + T opens Omabar (skipped if that combination is taken).
- Editor keys: ←/→, Delete, Ctrl+S save, Ctrl+T try on the bar, Enter takes the first icon search match. Busy rows shrink to fit, so every button and + stay visible.
- Bind descriptions come from the command, so restyling a button no longer reloads Hyprland.
- Fixed: an empty row crashed tiny-dfr ("layer has 0 buttons") and left the Touch Bar on its crash screen. The main row now needs at least one button, an empty Fn row gets F1–F12, and Omabar restarts tiny-dfr whenever it finds it crashed. `doctor` checks for it.
- Security: every text item in the panel and editor is plain text. Qt's default auto-detects HTML, so an app could set its window class to `<img src="https://…">` and make the shell load it when following the focused app (reported in marketplace review). A test now enforces plain text.
- Tests can't reach the real helper (`OMABAR_HELPER`), plus new editor tests (58 total).

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
