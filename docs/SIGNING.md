# Signing and Distribution Notes (Maintainers)

## Default distribution model
Contra is AMO-first.

- Users install from Firefox Add-ons Marketplace.
- Hardcore scripts default to AMO latest XPI URL derived from add-on ID.
- AMO manages updates.

## Manifest constraints
- Keep `browser_specific_settings.gecko.id` stable as `contra@lotmik`.
- Keep `browser_specific_settings.gecko.update_url` unset for AMO distribution.
- Keep data collection declaration aligned with AMO requirements.

## If AMO unlisted signing is needed
Use this fallback when testing non-listed channels.

1. Build package:
   - `scripts/build-xpi.sh`
2. Submit `dist/contra.xpi` to AMO as **Unlisted**.
3. Download signed XPI from AMO.
4. Host signed XPI on trusted HTTPS storage.
5. Install Hardcore policy with explicit URL override:
   - Linux/macOS:
     - `sudo bash scripts/hardcore-install.sh --install-url "https://example.com/contra.xpi"`
   - Windows:
     - `./scripts/hardcore-install.ps1 --install-url "https://example.com/contra.xpi"`

## Why add-on ID stability matters
Firefox enterprise policy mapping uses add-on ID key in `ExtensionSettings`.
If the ID changes, Hardcore Mode policy no longer targets the installed add-on.
