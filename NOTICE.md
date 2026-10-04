# Third-party notices

- **Icons** in `icons/` are [Material Symbols](https://github.com/google/material-design-icons)
  by Google, licensed under the [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0).
  Omabar ships them uncoloured and adds a fill colour when it installs them.
  Ten of them (brightness, media, volume, mic mute, search) are the versions shipped with tiny-dfr
  (MIT), so the Touch Bar looks the same as tiny-dfr's defaults.
- **tiny-dfr** ([AsahiLinux/tiny-dfr](https://github.com/AsahiLinux/tiny-dfr), MIT) draws the Touch Bar.
  Omabar generates its config; it doesn't include tiny-dfr's code.
- The idea of rendering a JSON layout into a tiny-dfr config plus Hyprland binds comes from
  [austindixson/omarchy-touchbar](https://github.com/austindixson/omarchy-touchbar) (MIT).
  Omabar's renderer and bind writer are its own code.
