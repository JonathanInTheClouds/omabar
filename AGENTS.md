# Omabar: guide for AI agents

You are working on **Omabar** (`io.github.jonathanintheclouds.omabar`), an Omarchy shell plugin that manages the Touch Bar on Intel T2 MacBook Pros. A user pointed you here so you can change their Touch Bar: add or edit layouts, buttons, icons, colours and per-app rules, or fix something that broke.

**Read this whole file before changing anything.** It documents how the pieces fit together, the non-obvious failures already hit during development, and the rules that keep the system working.

Built and tested on a MacBookPro16,1 (16-inch 2019, 2008×60 Touch Bar, physical Esc key), Omarchy 4.0.4, `linux-t2` 7.2, `tiny-dfr` 0.3.7 (arch-mact2), systemd 261, and Hyprland with a **Lua** config.

---

## 1. Ground rules

1. **Start with `bin/omabar doctor`.** It checks hardware, tiny-dfr, the helper, the resume fix, the config, icons, binds, rules and every layout.
2. **Never edit files the plugin generates:** `/etc/tiny-dfr/config.toml`, `/etc/tiny-dfr/omabar_*.svg`, the `-- omabar begin/end` block in `~/.config/hypr/bindings.lua`, `~/.local/state/omabar/live.json` and `~/.cache/omabar/`. Change layouts or settings and run `omabar apply`/`retheme` instead.
3. **Don't edit built-in layouts in the plugin folder** for a user's own changes; plugin updates replace them. Copy the file to `~/.config/omarchy/omabar/layouts/` (same id overrides the built-in) and edit the copy.
4. **You can't see the Touch Bar.** Screenshots don't capture it. Verify through files and logs, and ask the user what the bar shows.
5. **Root access only goes through the helper** (`pkexec /usr/local/libexec/omabar-helper …`) or `system/install.sh`. Never run other plugin files as root. Never edit `/usr/share/omarchy/`.
6. Run `tests/smoke.sh` after changing code, and `omabar render <id>` after changing a layout.

---

## 2. Architecture

```
 Omarchy bar ──► Panel.qml (Quickshell, inside omarchy-shell, in the user's session)
                   │  runs as Process:
                   ▼
              bin/omabar (Python 3.11+)
                   │ 1. flock; read layout; expand weather; validate
                   │ 2. generate tinted icons for the colour mode → pkexec helper icons
                   │ 3. write Hyprland bind block (union of all layouts) if it differs
                   │ 4. render TOML → pkexec helper config --live
                   ▼
              /etc/tiny-dfr/config.toml ──inotify──► tiny-dfr (root daemon) ──► Touch Bar (appletbdrm DRM device)
                                                          │ button press = synthetic key event
                                                          ▼
                                              Hyprland bind (code:NNN) ──► runs the command
```

Key facts:

1. **tiny-dfr can only send key presses.** A button that runs a command sends a spare key, and a Hyprland bind maps that key to the command.
2. **tiny-dfr is static.** Its only live widgets are `Time` and `Battery`. Weather is simulated by rewriting the config. Active workspace, mic state and now-playing are impossible.
3. **Writing `/etc/tiny-dfr` needs root.** The helper plus a polkit rule make it passwordless for the installing user, from an active local session. tiny-dfr watches the config with inotify (one-shot `IN_CLOSE`/`IN_MOVED_TO` on the file), so `--live` rewrites it in place and the bar updates with **no restart and no blink**.
4. **Every command has its own unique key,** so the bind block holds all layouts' binds at once. Switching layouts never touches `bindings.lua`, which would reload Hyprland.

---

## 3. Files

### Plugin (`~/.config/omarchy/plugins/io.github.jonathanintheclouds.omabar/`)

| Path | Role |
|---|---|
| `manifest.json` | Plugin manifest (bar widget, entry `Panel.qml`). |
| `Panel.qml` | Bar button and popup (`bar-widget` entry). Watches focus (Hyprland `activewindow` events), runs the weather timer every 15 min, shows settings and setup state, opens the editor. |
| `Editor.qml` | The layout and rules editor (`panel` entry), a centred overlay. Open it with `omarchy-shell shell summon io.github.jonathanintheclouds.omabar '{"layout":"dev"}'` (or `'{"tab":"rules"}'`). The payload can also deep-link a state: `{"layout":"dev","row":"fnLayer","select":3,"picker":"icon"}`. Keys: ←/→ select, Delete removes, Ctrl+S saves, Ctrl+T tries on the bar, Esc closes; Enter in the icon search takes the first match. It draws icons from their path data (QtQuick.Shapes), so any icon and tint previews without installing. |
| `bin/omabar` | Backend. All logic lives here; the panel only displays `omabar list`. |
| `layouts/*.json` | Built-in layouts (17). |
| `icons/*.svg` | Uncoloured Material Symbols sources (filled, 48px, `viewBox="0 -960 960 960"`, a single `<path>`). |
| `system/install.sh`, `uninstall.sh` | One-time root setup and its undo. |
| `system/omabar-helper` | Root helper source. The installed copy is `/usr/local/libexec/omabar-helper`. |
| `system/omabar-resume.service`, `99-omabar-tiny-dfr.rules` | Sleep/resume fix (§10). |
| `tests/smoke.sh` | Sandbox tests: every layout, every theme's contrast, the bind writer, helper validation. |

### User data

| Path | What |
|---|---|
| `~/.config/omarchy/omabar/layouts/<id>.json` | The user's layouts (override built-ins by id). |
| `~/.config/omarchy/omabar/icons/<name>.svg` | The user's uncoloured icon sources (override built-ins by name). |
| `~/.config/omarchy/omabar/rules.json` | Settings and per-app rules (§8). Created on the first settings change. |
| `~/.local/state/omabar/live.json` | The expanded layout on the bar now. The panel judges "active" by it. Written only after a successful switch. |
| `~/.local/state/omabar/manual-pick` | The layout last activated by hand. |
| `~/.cache/omabar/` | `icons/` (tinted icons for the current colours), `weather.json`, `lock`. |
| `~/.config/omarchy/hooks/theme-set.d/omabar` | Installed automatically. Runs `omabar retheme` after `omarchy theme set`. |

### System (root-owned, from `install.sh`)

`/usr/local/libexec/omabar-helper`, `/etc/polkit-1/rules.d/50-omabar.rules` (the user can't read that directory, so don't test for the file), `/etc/udev/rules.d/99-omabar-tiny-dfr.rules`, `/etc/systemd/system/omabar-resume.service` (+ `*.target.wants`), `/etc/tiny-dfr/config.toml` (first line `# Generated by omabar`), `/etc/tiny-dfr/omabar_*.svg`, and possibly `/etc/tiny-dfr/config.toml.before-omabar` (the config that was there before).

---

## 4. Commands (`bin/omabar`)

| Command | Does |
|---|---|
| `list` | JSON for the panel: layouts (expanded, preview paths, `active`, `error`, `source`), settings, `palette`, `hardware`, `passwordless`, `ruleWarnings`. |
| `apply <id>` | Puts the layout on the bar and records it as the manual pick. |
| `render <id>` | Prints the TOML a layout would produce. Changes nothing. Use it to validate. |
| `auto [<app-id>]` | Follow mode. Asks `hyprctl activewindow -j` for the real focus (the argument is only a hint) and applies the layout the rules pick. |
| `refresh-weather` | Fetches weather and re-applies a live weather layout if the result changed. |
| `retheme` | Regenerates icons for the colour mode, installs them and reloads the bar. |
| `colors default\|theme` | Sets the colour mode and retheme. |
| `follow on\|off`, `empty-default on\|off` | Settings flags. |
| `doctor` | Health check. Exits 1 if anything needs fixing and prints the fix. |
| `editor-data` | JSON for the editor: raw layouts, icons with path data, palette, key presets, the user's Omarchy shortcuts (translated to tiny-dfr key combos), installed apps, rules, running app classes. |
| `save <id>` (stdin: layout JSON) | Saves as one of the user's layouts. Buttons with a `command` but no key get a spare key: an already-bound command reuses its key; otherwise the next free one from F13–F24, Prog1–4, then CTRL+ALT+SHIFT+F13–F24. Re-syncs binds and re-applies the layout if it's live. |
| `delete <id>` | Deletes a user layout. Built-ins can't be deleted (deleting an override brings the built-in back). |
| `try` / `restore` | Put a draft (stdin) on the bar for up to 30 s (`~/.cache/omabar/trial-until` pauses follow mode and weather), then put the live layout back. Commands new in the draft don't run until saved. |
| `save-rules` (stdin) | Validates and saves `rules`, `default` and `shortcut`. |
| `migrate` | Imports settings from the `jonathan.touchbar-layouts` prototype and removes the austindixson bind block. |

All commands that change things take an flock (`~/.cache/omabar/lock`), so focus changes, the weather refresh and clicks never interleave.

---

Set `OMABAR_HELPER` to a missing path to make the backend act as if the helper isn't installed. **Tests must do this:** without it, `try`/`apply` in a sandboxed `$HOME` still reach the real helper and the real Touch Bar (this happened once during development).

## 5. Layout format

```json
{
  "name": "Dev",
  "description": "Workspaces 1–4, then terminal, editor, lazygit…",
  "mediaLayerDefault": true,
  "showButtonOutlines": false,
  "adaptiveBrightness": true,
  "fontTemplate": "JetBrainsMono Nerd Font:bold",
  "buttons": [
    { "text": "1", "key": ["LeftMeta", "Num1"] },
    { "spacer": true, "stretch": 1 },
    { "icon": "terminal", "tint": "accent", "key": "F13", "hyprKey": "code:191", "command": "omarchy-launch-terminal" },
    { "icon": "play_pause", "tint": "foreground", "key": "PlayPause" },
    { "weather": "icon" }, { "weather": "temp" },
    { "time": "%-I:%M %p", "stretch": 2 },
    { "battery": "both", "stretch": 2 }
  ],
  "fnLayer": [ { "text": "F1", "key": "F1" } ]
}
```

| Field | Meaning |
|---|---|
| `name`, `description` | Shown in the panel. |
| `mediaLayerDefault` | `true` (all built-ins): `buttons` shows normally, `fnLayer` while Fn is held. |
| `showButtonOutlines` | Grey rounded keys, or borderless. |
| `fontTemplate` | fontconfig pattern for text and clocks. Built-ins use JetBrains Mono Nerd Font, so Nerd glyphs work in `text`. |
| `weatherUnit` | `"F"`/`"C"`. Defaults to °F for `LANG=en_US`. |

| Button | Notes |
|---|---|
| `icon` + `tint` | `icon` is a file name in `icons/` (no extension). `tint` is `accent`, `foreground`, `dim`, `danger` or `white` (default `white`). |
| `text` | **Always drawn white** by tiny-dfr. Colour is only possible through icons. |
| `key` | One name or a list for a combo. Names come from the Rust `input-linux` `Key` enum: `LeftMeta`, `LeftCtrl`, `LeftAlt`, `LeftShift`, `Num1`, `F13`, `Comma`, `Space`, `Backspace`, `PageUp`, `Kp0`, `KpEnter`, `Prog1`, `PlayPause`, `BrightnessUp`… |
| `hyprKey` + `command` | Make the button run a command through a Hyprland bind (§6). |
| `spacer` | An empty gap. |
| `stretch` | Relative width (integer ≥ 1). |
| `time` | strftime, e.g. `"%-I:%M %p"`, `"%a %b %-d"`. Optional `locale`. |
| `battery` | `"icon"`, `"percentage"` or `"both"`. Green while charging, red under 10%. |
| `weather` | `"icon"` or `"temp"`. Placeholders the backend fills in; tapping opens Omarchy's weather panel. |

Limits: about **24 buttons per row**. A glyph plus a word of up to 5 letters fits a single-width key in a 12-unit row; give denser text keys `"stretch": 2` ("mirror", "blank" and "paste" overflowed in mockups). `validate()` in `bin/omabar` rejects anything that could crash tiny-dfr.

---

## 6. Keys, codes and binds

Hyprland binds use **`code:` = Linux evdev keycode + 8** (the old X11 offset). Binding by code is required because the US XKB layout names F13+ things like `XF86Tools`, so a bind on `F13` never fires.

| Key sent | `hyprKey` | Command |
|---|---|---|
| Search | `XF86Search` | `omarchy-menu toggle` |
| F13 / F14 / F15 | `code:191` / `192` / `193` | terminal / browser / Nautilus (`omarchy-launch-*`) |
| F16 | `code:194` | weather tap: `omarchy-shell omarchy.weather toggle` |
| F17–F21 | `code:195`–`199` | `omarchy capture screenshot region`, `… screenrecording`, `… text`, `… qr`, `hyprpicker -a` |
| F22 | `code:200` | **free** |
| F23 / F24 | `code:201` / `202` | `omarchy-launch-spotify` / `omarchy-launch-editor` |
| Prog1 / Prog2 | `code:156` / `157` | `omarchy-launch-tui lazygit` / `omarchy-launch-docker-tui` |
| CTRL+ALT+SHIFT + F13–F18 | `CTRL + ALT + SHIFT + code:191`–`196` | `omarchy theme set hackerman / tokyo-night / catppuccin / gruvbox / nord / rose-pine` |
| CTRL+ALT+SHIFT + F19 / F20 | `… code:197` / `198` | `omarchy bluetooth power toggle` / `omarchy hyprland monitor internal mirror toggle` |
| CTRL+ALT+SHIFT + F21–F24 | | **free** |

For a combo, `key` is `["LeftCtrl","LeftAlt","LeftShift","F19"]` and `hyprKey` is `"CTRL + ALT + SHIFT + code:197"`.

- **The same `hyprKey` must mean the same command in every layout.** The first one found wins.
- **Prefer sending an existing Omarchy shortcut** to adding a bind. List them with `hyprctl binds -j | jq -r '.[] | "\(.modmask)|\(.key)|\(.description)"'` (modmask SUPER 64, CTRL 4, ALT 8, SHIFT 1). Users customise these: on the reference machine SUPER+W is "close tab (Chromium/VS Code) / close window".
- Bind descriptions ("Touch Bar: terminal") come from the **command**, never the icon, so restyling a button never rewrites `bindings.lua` (each rewrite reloads Hyprland).
- **Omarchy's `Dropdown`/`SearchableDropdown` assign their own `value` when picked**, which breaks a QML binding. The editor wraps them (`BoundDropdown`, `BoundSearch`) to re-bind after each pick; use those for any dropdown bound to state.
- **Never use old-style `hyprctl dispatch name args`.** This Hyprland uses a Lua config. The Lua form is `hyprctl dispatch 'hl.dsp.focus({ workspace = "5" })'`.

---

## 7. Icons and colours

- Sources are uncoloured. At apply or retheme time the backend writes `omabar_<tint>_<icon>.svg` to `~/.cache/omabar/icons/`, adding `fill` on `<path>`. Qt (the panel preview) ignores a fill on the root `<svg>`, which is why tiny-dfr's own `battery_*.svg` preview black and the panel draws the battery in QML.
- The helper installs **exactly** that set into `/etc/tiny-dfr` and removes stale `omabar_*` icons. tiny-dfr's stock icons are never touched. Icons install automatically on apply, so no separate step is needed.
- **Colour modes** (`"colors"` in rules.json):
  - `default` — Omabar's own palette: accent `#82FB9C`, foreground `#DDF7FF`, dim `#B5C5DB`, danger `#FF5F6D`, white.
  - `theme` — from `~/.local/state/omarchy/current/theme/colors.toml`: `accent`, the first of `foreground`/`light_foreground`/`dark_foreground` with contrast ≥ 6:1 on black, `dim` from `light_foreground` or a darker foreground, and `danger` from the theme's `red` **only if it is actually red** (Hackerman's is green). Anything too dark is lightened until it reads on black, which matters for light themes. The theme-set hook recolours on theme change.
- **Adding an icon:** put an uncoloured SVG in `~/.config/omarchy/omabar/icons/<name>.svg` (checked before the plugin's `icons/`, and safe from plugin updates). Material Symbols match the built-ins:
  `https://raw.githubusercontent.com/google/material-design-icons/master/symbols/web/<name>/materialsymbolsoutlined/<name>_fill1_48px.svg`
  The helper only accepts plain SVGs: no scripts, entities, `href`, `url(`, or anything over 64 KiB.
- **Nerd Font glyphs in `text`:** check they exist with `fc-list ':charset=f0156' family | grep JetBrainsMono`, and render a preview to confirm the meaning: `magick -background black -fill white -font /usr/share/fonts/TTF/JetBrainsMonoNerdFont-Bold.ttf -pointsize 34 label:"$(printf '\U000F0156 close')" out.png`.

---

## 8. Follow mode and settings (`~/.config/omarchy/omabar/rules.json`)

```json
{
  "colors": "default",
  "follow": false,
  "emptyDefault": true,
  "default": "duotone-weather",
  "shortcut": "SUPER + ALT + T",
  "rules": [
    { "app": "Alacritty|kitty|com.mitchellh.ghostty|foot|org.omarchy.agent", "layout": "dev" },
    { "app": "chromium|google-chrome|firefox|brave-browser|zen", "layout": "browser" }
  ]
}
```

Decisions in `cmd_auto`:
1. If `follow` is off, or the helper is missing, do nothing. Without the helper every switch would bring up a password prompt.
2. Ask Hyprland for the focused window. **Don't trust the event alone:** closing a popup that grabbed the keyboard (including this panel) emits `activewindow>>,` and never re-announces the app.
3. A rule matches the whole window class, case-insensitively, as a regex. The first match wins.
4. No matching rule, or a class-less window (treated as app `"?"`): the **manual pick**, else `default`.
5. No window at all: if `emptyDefault` is on, the manual pick, else `default`. If it's off, keep the current layout.

Find a window's class with `hyprctl activewindow -j | jq -r .class`.

`shortcut` (default `SUPER + ALT + T`, empty for none) is written into the bind block and runs `omarchy-shell io.github.jonathanintheclouds.omabar toggle`, which opens the popup through its IPC target. Summoning the plugin id opens the editor instead, because the plugin has a `panel` entry. It's skipped if any other bind already uses that combination. Broken regexes and unknown layout ids show in red in the panel and in `doctor`.

---

## 9. Weather

Placeholders expand from `~/.cache/omabar/weather.json`. The data comes from Open-Meteo (`temperature_2m, weather_code, is_day`). Location is Omarchy's `~/.local/state/omarchy/settings/weather.json` if set, otherwise an IP lookup through `wttr.in`, cached. The panel's `Timer` refreshes every 15 min and re-applies only when the displayed weather changed. It must run **inside the shell**, not as a systemd user timer: user services aren't in the logind session, and the polkit rule requires an active local one.

---

## 10. Sleep and resume

On resume the T2 re-attaches the Touch Bar. tiny-dfr panics with `No such device (os error 19)`, and its `BindsTo=dev-tiny_dfr_display.device` makes systemd **stop** it. `Restart=always` doesn't apply to a stop, and on Intel T2 the stock unit only starts at boot, so the bar stays blank.

- **Doesn't work:** a udev rule alone. The new display appears about 20 ms before systemd processes the crash, so the start request is ignored.
- **Doesn't work:** a hook in `/etc/systemd/system-sleep/`. systemd 261 only runs hooks from `/usr/lib/systemd/system-sleep/`.
- **Works (confirmed on hardware):** `omabar-resume.service`, ordered after the sleep targets, which sleeps 2 s, runs `reset-failed` and restarts tiny-dfr. The bar returns about 2–3 s after the screen.

### Not Omabar: AMD dGPU resume hangs

On 16-inch models the internal display can be driven by the AMD Navi 14 dGPU. That GPU has failed to resume at least once (after the 5th suspend of a long session): `amdgpu_irq_put` warnings, `ring sdma0 timeout`, "device wedged", and omarchy-shell aborting inside Mesa, ending in a forced restart. **That is a dGPU/driver problem, not Omabar.** The Touch Bar is a separate USB display that Omabar's code never touches. If `bin/omabar doctor` is clean after the restart, look at the GPU. The full analysis, with commands to check: `docs/incidents/2026-10-04-amdgpu-resume-hang.md`.

---

## 11. First-time setup (what `install.sh` does)

1. Installs `tiny-dfr` (arch-mact2) if missing and **enables** it. The package's `t2-intel.conf` drop-in replaces the Apple Silicon udev auto-start with `WantedBy=graphical.target`, so without enabling it never starts.
2. Moves a config Omabar didn't write to `config.toml.before-omabar`. tiny-dfr merges `/usr/share/tiny-dfr/config.toml` with `/etc`.
3. Installs the helper, the polkit rule, the udev rule and the resume service. It removes the prototype's (`jonathan.touchbar-layouts`) system files and `omarchy_*.svg` icons.
4. The Touch Bar USB device (05ac:8302) starts in configuration 1, Apple's keyboard mode (`hid_appletb_kbd`). tiny-dfr's udev rule switches it to configuration 2 (`appletbdrm` display) only when the device is added. `install.sh` writes `bConfigurationValue` itself. If no `appletbdrm` card appears, a reboot is needed.

---

## 12. Omarchy shell gotchas

- Saving plugin files hot-reloads the plugin, but the **old `IpcHandler` stays registered**, so `omarchy-shell io.github.jonathanintheclouds.omabar open` can show a stale panel. Run `omarchy restart shell` before testing UI changes.
- QML errors are logged in `$(ls -t /run/user/$UID/quickshell/by-id/*/log.log | head -1)`.
- `grim -g "X,Y WxH"` takes **logical** coordinates (the scale is about 1.6 on the reference machine).
- Some themes' `Color.urgent` is green (Hackerman), so don't use it to mean "off".
- UI components (`Panel`, `KeyboardPanel`, `PanelKeyCatcher`, `Button`, `Dropdown`, `ToggleSwitch`, `PanelSeparator`, `BarIconButton`) come from `qs.Ui`. Read them in `/usr/share/omarchy/shell/Ui/`.

---

## 13. Recipes

- **New layout:** copy a built-in from `layouts/` to `~/.config/omarchy/omabar/layouts/<new-id>.json`, edit it, run `omabar render <new-id>`, and pick it in the panel.
- **Launcher button:** take a free key from §6, add `"hyprKey"` and `"command"`, and confirm the command exists (`command -v …`, or `omarchy <group> <cmd> --help`). After activating, check `hyprctl binds -j | jq '[.[]|select(.description|startswith("Touch Bar"))]|length'` and `hyprctl configerrors`.
- **Shortcut button:** `"key": ["LeftMeta","LeftCtrl","N"]`, after confirming the bind exists.
- **Per-app rule:** add `{"app": "<class regex>", "layout": "<id>"}` to rules.json.
- **Edit the live layout:** the panel shows **Activate** instead of **● ACTIVE**; press it or run `omabar apply <id>`.
- **Change colours:** `omabar colors theme` or `default`. To change Omabar's own palette, edit `DEFAULT_PALETTE` in `bin/omabar`, then run `omabar retheme`.

---

## 14. Testing

```bash
tests/smoke.sh                        # sandboxed: layouts, every theme's contrast, binds, helper checks
bin/omabar doctor                     # the real system
bin/omabar render <id>                # one layout's TOML
hyprctl configerrors                  # after binds change
systemctl show tiny-dfr -p ActiveEnterTimestamp   # unchanged across --live switches
journalctl -b -u tiny-dfr -u omabar-resume | tail
```
Test focus changes with `hyprctl dispatch 'hl.dsp.focus({ workspace = "5" })'` and `jq -r .name ~/.local/state/omabar/live.json`.

---

## 15. Known limits

- Only tested on a 16-inch 2019 MacBook Pro. The 13- and 15-inch bars are 2170 px wide; the preview reads the real width from the DRM connector, but layouts were tuned at 2008 px.
- Apple Silicon Macs aren't supported: tiny-dfr works there, but the service setup and resume behaviour differ.
- Layouts can't show live state beyond clock, battery and weather.
- Text is always white.
